import QtQuick

// Right-hand pane: WORLD / FAVORITES / RECENT tabs, kind filter chips and the
// virtualized camera list. Rows are computed by Vantage.qml.
Item {
  id: root

  property var rows: []
  property string tab: "world"
  property var kindOn: ({ video: true, loop: true, snapshot: true })
  property var favSet: ({})
  property string selectedId: ""
  property string heading: ""
  property string emptyText: ""

  signal tabPicked(string tab)
  signal kindToggled(string kind)
  signal camClicked(var cam)
  signal favClicked(var cam)

  function scrollTop() { list.positionViewAtBeginning() }
  onRowsChanged: list.positionViewAtBeginning()

  Rectangle { anchors.fill: parent; color: Vt.a(Vt.panel, 1) }
  Rectangle { x: 0; width: 1; height: parent.height; color: Vt.lineDim }

  Column {
    id: top
    x: 12
    y: 10
    width: root.width - 24
    spacing: 10

    Row {
      spacing: 0
      Repeater {
        model: [
          { k: "world", t: "WORLD" }, { k: "favorites", t: "FAVORITES" }, { k: "recent", t: "RECENT" }
        ]
        delegate: Item {
          required property var modelData
          width: tabText.implicitWidth + 24
          height: 28
          Rectangle {
            anchors.fill: parent
            color: root.tab === modelData.k ? Vt.a(Vt.accent, 0.22) : "transparent"
            border.width: 1
            border.color: root.tab === modelData.k ? Vt.line : Vt.lineDim
          }
          Text {
            id: tabText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.t
            color: root.tab === modelData.k ? Vt.accent : Vt.textDim
            font.family: Vt.mono
            font.pixelSize: Vt.fsSmall
            font.bold: root.tab === modelData.k
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tabPicked(modelData.k) }
        }
      }
    }

    Row {
      spacing: 6
      VtChip { glyph: "█"; label: "LIVE"; on: root.kindOn.video; onToggled: root.kindToggled("video") }
      VtChip { glyph: "▒"; label: "LOOP"; on: root.kindOn.loop; onToggled: root.kindToggled("loop") }
      VtChip { glyph: "░"; label: "SNAP"; on: root.kindOn.snapshot; onToggled: root.kindToggled("snapshot") }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.heading
      color: Vt.textFaint
      font.family: Vt.mono
      font.pixelSize: Vt.fsCaption
      elide: Text.ElideRight
    }
  }

  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: top.bottom
    anchors.topMargin: 6
    anchors.bottom: parent.bottom
    clip: true
    model: root.rows
    boundsBehavior: Flickable.StopAtBounds
    delegate: CamRow {
      required property var modelData
      width: list.width
      cam: modelData
      fav: root.favSet[modelData.id] === true
      selected: root.selectedId === modelData.id
      unavailable: modelData.unavailable === true
      onClicked: root.camClicked(modelData)
      onFavClicked: root.favClicked(modelData)
    }
    Text {
      anchors.centerIn: parent
      width: parent.width - 40
      visible: root.rows.length === 0
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: root.emptyText
      color: Vt.textFaint
      font.family: Vt.mono
      font.pixelSize: Vt.fsSmall
    }
  }
}
