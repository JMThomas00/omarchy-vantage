import QtQuick
import Quickshell
import Quickshell.Io

// A Process that runs its helper through bin/supervise.sh, so nothing the
// helper starts can outlive it: the supervisor puts the whole tree in its own
// process group and turns one signal into TERM-then-KILL for the group. Used
// for the catalog build (bin/catalog-build.py). The caller owns `stdout`
// directly, so progress lines can be read while the helper is still running.
//
// Copied from the author's Lookout plugin (MIT); bin/supervise.sh is vendored
// from scoop.uptime-kuma (MIT) -- see THIRD_PARTY_LICENSES.md.
//
// `deadlineSeconds` bounds the run (0 = no deadline); a QML-side watchdog backs
// up the supervisor's own deadline in case the supervisor itself is wedged.
Process {
    id: root

    /** The helper to run, as an argv array. Set this, not `command` -- see the header comment. */
    property var program: []

    /** Seconds before a QML-side watchdog backs up supervise.sh's own deadline. 0 = no deadline. */
    property int deadlineSeconds: 0

    readonly property string _supervisor: Qt.resolvedUrl("bin/supervise.sh").toString().replace("file://", "")

    command: program.length > 0 ? [_supervisor, String(deadlineSeconds)].concat(program) : []

    clearEnvironment: true
    environment: ({
            PATH: "/usr/bin:/bin",
            DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
            XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            HOME: Quickshell.env("HOME"),
            LC_ALL: "C",
        })

    onStarted: if (deadlineSeconds > 0) watchdog.restart()

    /** Stop the whole process group: TERM now, KILL after a grace period. */
    function _tearDown() {
        if (running) {
            signal(15);
            killTimer.restart();
        }
    }

    onExited: {
        killTimer.stop();
        watchdog.stop();
    }

    Component.onDestruction: root._tearDown()

    property Timer watchdog: Timer {
        interval: (root.deadlineSeconds + 5) * 1000
        repeat: false
        running: false
        onTriggered: root._tearDown()
    }

    property Timer killTimer: Timer {
        interval: 6000
        repeat: false
        onTriggered: if (root.running) root.signal(9)
    }
}
