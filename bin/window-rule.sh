#!/usr/bin/env bash
# Register Hyprland window rules for Vantage's own windows (main panel and the
# snapshot viewers). mpv viewers need no rule: Omarchy already floats and
# centers `mpv` by default.
#
# Opacity is deliberately NOT set here: Vantage follows Omarchy's own default-opacity tag, so
# it is translucent like your other windows and SUPER+BACKSPACE (which toggles the window's
# `opaque` property) works on it. Forcing opacity in this rule would defeat that toggle.
#
# On a Lua-configured Hyprland (Omarchy default) rules are added at runtime via
# `hyprctl eval`; the legacy `hyprctl keyword` form is rejected there.
#
# Usage: window-rule.sh <width> <height>
set -euo pipefail

w=${1:-}
h=${2:-}
[[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || { echo "usage: window-rule.sh WIDTH HEIGHT" >&2; exit 2; }

[[ $(hyprctl -j status | jq -r '.configProvider // ""') == lua ]] || exit 2

read -r -d '' setup <<LUA || true
if _G.omarchy_vantage_rule then _G.omarchy_vantage_rule:set_enabled(false) end
if _G.omarchy_vantage_snap_rule then _G.omarchy_vantage_snap_rule:set_enabled(false) end
-- Rules are keyed by name, and re-creating a rule with an existing name can keep the
-- properties of the old one (an old opacity survived an edit). A fresh name per run
-- means each run's rule is exactly what this script says.
_G.omarchy_vantage_gen = (_G.omarchy_vantage_gen or 0) + 1
local gen = _G.omarchy_vantage_gen

_G.omarchy_vantage_rule = hl.window_rule({
  name = "vantage-plugin-" .. gen,
  match = { initial_class = "^org[.]quickshell\$", initial_title = "^Vantage\$" },
  float = true,
  center = true,
  size = { $w, $h },
  no_anim = true,
  border_size = 0,
})

_G.omarchy_vantage_snap_rule = hl.window_rule({
  name = "vantage-snapshot-" .. gen,
  match = { initial_class = "^org[.]quickshell\$", initial_title = "^Vantage snapshot.*$" },
  float = true,
  center = true,
  size = { 880, 560 },
  no_anim = true,
  border_size = 0,
})
LUA

response=$(hyprctl eval "$setup")
[[ $response == ok ]] || { echo "$response" >&2; exit 1; }
