import QtQuick
import Quickshell.Io
import qs.Commons

// Reads the CURRENT theme's colors.toml so Vantage can offer palette choices
// (green, amber, cyan, ...) that come from the active Omarchy theme.
//
// The shell pushes a live theme switch straight into its own singletons and does
// not re-read files (see the dev notes), so this re-reads the file itself: when the
// panel opens, and shortly after Color.accent changes.
Item {
  id: root

  property bool active: false
  property var colors: ({})
  readonly property string path: Color.currentThemePath + "/colors.toml"

  function reload() { file.reload() }

  function _parse(raw) {
    var out = {}, lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/.exec(lines[i])
      if (m) out[m[1]] = m[2]
    }
    root.colors = out
  }

  FileView {
    id: file
    path: root.active ? root.path : ""
    watchChanges: false
    printErrors: false
    onLoaded: root._parse(text())
  }

  Connections {
    target: Color
    function onAccentChanged() { settle.restart() }
    function onBackgroundChanged() { settle.restart() }
  }
  Timer { id: settle; interval: 600; onTriggered: root.reload() }
  onActiveChanged: if (root.active) root.reload()
}
