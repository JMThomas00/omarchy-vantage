import QtQuick

// One row in the sidebar list: shade-block kind badge, name, place, star.
Item {
  id: root
  property var cam: null
  property bool fav: false
  property bool selected: false
  property bool unavailable: false
  signal clicked()
  signal favClicked()

  height: 46

  Rectangle {
    anchors.fill: parent
    color: root.selected ? Vt.a(Vt.accent, 0.20) : (rowMouse.containsMouse ? Vt.a(Vt.accent, 0.08) : "transparent")
  }
  Rectangle {   // selection marker
    width: 3
    height: parent.height
    color: Vt.accent
    visible: root.selected
  }

  Text {
    id: kind
    x: 12
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.cam ? Vt.shade(root.cam.kind) : ""
    color: root.unavailable ? Vt.textFaint : Vt.accent
    font.family: Vt.mono
    font.pixelSize: Vt.fsTitle
  }

  Column {
    anchors.left: kind.right
    anchors.leftMargin: 10
    anchors.right: star.left
    anchors.rightMargin: 6
    anchors.verticalCenter: parent.verticalCenter
    spacing: 2
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.cam ? root.cam.name : ""
      color: root.unavailable ? Vt.textFaint : Vt.text
      font.family: Vt.mono
      font.pixelSize: Vt.fsSmall
      font.bold: root.selected
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.cam ? ((root.unavailable ? "UNAVAILABLE  ·  " : "") + (root.cam.place || "")) : ""
      color: Vt.textDim
      font.family: Vt.mono
      font.pixelSize: Vt.fsCaption
      elide: Text.ElideRight
    }
  }

  Text {
    id: star
    anchors.right: parent.right
    anchors.rightMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.fav ? "★" : "☆"
    color: root.fav ? Vt.accent : Vt.textFaint
    font.family: Vt.mono
    font.pixelSize: Vt.fsTitle
    MouseArea {
      anchors.fill: parent
      anchors.margins: -8
      cursorShape: Qt.PointingHandCursor
      onClicked: root.favClicked()
    }
  }

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    z: -1
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
