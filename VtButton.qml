import QtQuick

// Bracketed terminal button: "[ RANDOM ]". Plain Rectangle + MouseArea on
// purpose (no QtQuick.Controls Button: sidesteps the qs.Ui.Button font and
// checkable pitfalls, and gives full control of the look).
Item {
  id: root
  property string label: ""
  property bool active: false
  property bool primary: false
  property bool enabled2: true
  property int pad: 12
  property color swatch: "transparent"   // optional filled square before the label
  readonly property bool hasSwatch: swatch.a > 0
  signal clicked()

  implicitWidth: txt.implicitWidth + pad * 2 + (hasSwatch ? 14 : 0)
  implicitHeight: 28
  opacity: root.enabled2 ? 1 : 0.4

  Rectangle {
    anchors.fill: parent
    color: (root.active || root.primary) ? Vt.a(Vt.accent, root.primary ? 0.9 : 0.24)
         : (mouse.containsMouse ? Vt.a(Vt.accent, 0.12) : "transparent")
    border.width: 1
    border.color: (root.active || root.primary || mouse.containsMouse) ? Vt.line : Vt.lineDim
  }
  Rectangle {
    visible: root.hasSwatch
    width: 8; height: 8
    x: root.pad - 2
    anchors.verticalCenter: parent.verticalCenter
    color: root.swatch
  }
  Text {
    id: txt
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: root.hasSwatch ? 7 : 0
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: "[ " + root.label + " ]"
    color: root.primary ? Vt.panel : Vt.accent
    font.family: Vt.mono
    font.pixelSize: Vt.fsSmall
    font.bold: root.primary || root.active
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.enabled2
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
