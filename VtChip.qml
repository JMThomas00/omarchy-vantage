import QtQuick

// Filter chip led by a shade block: "█ LIVE" (on) / dimmed (off).
Item {
  id: root
  property string glyph: "█"
  property string label: ""
  property bool on: true
  signal toggled()

  implicitWidth: row.implicitWidth + 18
  implicitHeight: 26

  Rectangle {
    anchors.fill: parent
    color: root.on ? Vt.a(Vt.accent, 0.16) : "transparent"
    border.width: 1
    border.color: root.on ? Vt.line : Vt.lineDim
  }
  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6
    Text { textFormat: Text.PlainText; text: root.glyph; color: root.on ? Vt.accent : Vt.textFaint
           font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
    Text { textFormat: Text.PlainText; text: root.label; color: root.on ? Vt.text : Vt.textFaint
           font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
  }
  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggled() }
}
