#!/usr/bin/bash
#
# Vendored, unmodified, from scoop.uptime-kuma's bin/supervise.sh (MIT,
# Copyright (c) 2026 Patrick Lenz) -- see ../THIRD_PARTY_LICENSES.md.
#
# Run one helper so that nothing it starts can outlive it.
#
# A helper here is a shell script that builds a pipeline — curl, jq, head, tr.
# Signalling the script reaches the script and nothing else: its curl is a
# separate process with a separate pid, and the shell exiting merely reparents
# it to init, where it keeps the connection open and keeps holding the session
# cookie. Cancelling a poll, or refusing an oversized response, has to reach the
# whole tree or it has not cancelled anything.
#
# So the helper is run as a background job with job control switched on, which
# is what makes bash put it in a process group of its own with the job's pid as
# the group id. Everything it forks inherits that group, and `kill -- -$job`
# then names the whole tree in one call. timeout holds the deadline and turns
# both its own expiry and a signal arriving from outside into TERM to that
# group, SIGKILL after the grace period — and this script confirms afterwards
# that the group is actually gone rather than assuming the signal worked.
#
# Usage: supervise.sh <deadline-seconds> <program> [args...]
#
# A deadline of 0 means no deadline: the polling session is meant to run until
# it is stopped, and is bounded by its caller noticing that it has gone quiet.
# Every other caller passes a number.
#
# The program must be named by absolute path. This is the one door every helper
# comes through, so it is the place to make sure PATH never gets to decide which
# curl, or which login.sh, is the one holding a credential.
#
# stdin, stdout and stderr are the helper's own, so this is transparent to
# callers that feed a credential in on stdin. The exit status is the helper's,
# except when the deadline fires — 124, or a signal status when the group had to
# be killed — and 64 for a usage error here.

set -uo pipefail

# Between TERM and KILL. Long enough for curl to close a connection, short
# enough that a stuck helper does not delay a reconnect.
GRACE=2

# How long to wait for the group to disappear after SIGKILL, in tenths of a
# second. A kill that is not confirmed is a kill that may not have happened.
REAP_TRIES=50

usage() {
    echo "usage: supervise.sh <deadline-seconds> </absolute/program> [args...]" >&2
    exit 64
}

deadline="${1-}"
[[ "$deadline" =~ ^[0-9]+$ ]] || usage
shift
(($# >= 1)) || usage
[[ "$1" == /* ]] || usage

# Job control: without it a background job stays in this shell's own process
# group, `kill -- -$job` has no group of its own to name, and the signal either
# fails or lands on this script as well.
set -m
/usr/bin/timeout --signal=TERM --kill-after="$GRACE" -- "$deadline" "$@" &
job=$!
set +m

group_alive() {
    kill -0 -- -"$job" 2>/dev/null
}

# Bring the whole group down and then check that it came down.
#
# timeout escalates on its own — an externally delivered TERM makes it signal
# the group and arm SIGKILL for GRACE seconds later — so the wait below is
# bounded even when the helper ignores TERM. If timeout itself was killed
# outright, nothing escalated and the KILL here is what ends the group.
#
# Signalling by number is only safe while the number cannot have been reused,
# which is why nothing here signals a group it has not just seen alive: a
# process group id stays reserved for as long as the group has a member, and
# until `wait` returns it is also pinned by this shell's own unreaped child.
stop_group() {
    local i
    if group_alive; then
        kill -TERM -- -"$job" 2>/dev/null
    fi
    wait "$job" 2>/dev/null
    group_alive || return 0
    kill -KILL -- -"$job" 2>/dev/null
    for ((i = 0; i < REAP_TRIES; i++)); do
        group_alive || return 0
        /usr/bin/sleep 0.1
    done
    echo "supervise: process group $job survived SIGKILL" >&2
    return 1
}

# A signal has to end this script, not merely tidy up: a handler that cleans up
# and returns hands control back to the `wait` it interrupted, and the helper
# carries on.
on_signal() {
    trap - EXIT INT TERM HUP
    stop_group
    exit 143
}
trap stop_group EXIT
trap on_signal INT TERM HUP

# 2>/dev/null: bash announces a job that died from a signal ("Killed"), and
# that announcement would otherwise land on the helper's own stderr, where the
# panel reads it as a diagnostic from the helper.
wait "$job" 2>/dev/null
rc=$?

# The helper has exited; anything it left behind has not. The EXIT trap is what
# takes that down — on this path and on every other one.
exit "$rc"
