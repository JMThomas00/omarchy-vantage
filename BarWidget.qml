import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Vantage bar icon. Left click toggles the globe, middle click summons a
// random camera. The panel itself lives in Vantage.qml (a `panel` plugin).
BarWidget {
  id: root
  moduleName: "jmthomas00.vantage"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Vantage: live webcams (middle-click: random)"

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        Quickshell.execDetached(["omarchy-shell", "shell", "summon", "jmthomas00.vantage", "{\"action\":\"random\"}"])
        return
      }
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "jmthomas00.vantage"])
    }
  }

  IpcHandler {
    target: "jmthomas00.vantage"

    function open(): void { Quickshell.execDetached(["omarchy-shell", "shell", "summon", "jmthomas00.vantage"]) }
    function close(): void { Quickshell.execDetached(["omarchy-shell", "shell", "hide", "jmthomas00.vantage"]) }
    function toggle(): void { Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "jmthomas00.vantage"]) }
    function random(): void { Quickshell.execDetached(["omarchy-shell", "shell", "summon", "jmthomas00.vantage", "{\"action\":\"random\"}"]) }
    // e.g. bind a key to a favourite camera: select yt:earthcam-times-square-north
    function select(id: string): void { Quickshell.execDetached(["omarchy-shell", "shell", "summon", "jmthomas00.vantage", JSON.stringify({ action: "select", id: id })]) }
    function watch(id: string): void { Quickshell.execDetached(["omarchy-shell", "shell", "summon", "jmthomas00.vantage", JSON.stringify({ action: "watch", id: id })]) }
  }
}
