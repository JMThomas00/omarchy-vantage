import QtQuick
import "Viewer.js" as ViewerJs

// Thumbnail preview for the selected camera. Click the thumbnail (or WATCH) to
// open the floating live view. The thumbnail refreshes on a timer using an A/B
// crossfade: a refresh loads into the hidden Image and only flips visibility
// once it is Ready, so the on-screen Image's source is never touched (a single
// re-bound Image blanks to its placeholder on every refresh).
Item {
  id: root

  property var cam: null
  property bool fav: false
  property bool connecting: false
  property string srcLabel: ""
  property bool scanlines: false
  property bool running: true

  signal watch()
  signal toggleFav()
  signal closeRequested()

  property real maxWidth: 372
  width: Math.max(260, Math.min(372, root.maxWidth))
  height: col.implicitHeight + 28
  visible: root.cam !== null

  property bool aFront: true
  property int gen: 0
  property bool hasFrame: false
  property bool failed: false

  function _url() {
    var u = root.cam ? root.cam.thumb : ""
    if (!u || !ViewerJs.urlAllowed(u)) return ""
    return u + (u.indexOf("?") >= 0 ? "&" : "?") + "vt=" + (++root.gen)
  }

  function _reset() {
    root.hasFrame = false
    root.failed = false
    root.aFront = true
    imgB.source = ""
    imgA.source = root._url()
  }

  function _refresh() {
    if (!root.cam || !root.running) return
    var u = root._url()
    if (!u) return
    if (root.aFront) imgB.source = u
    else imgA.source = u
  }

  onCamChanged: root._reset()
  Component.onCompleted: if (root.cam) root._reset()

  Timer {
    interval: Math.max(20, root.cam ? root.cam.refresh : 60) * 1000
    running: root.visible && root.running && root.cam !== null
    repeat: true
    onTriggered: root._refresh()
  }

  // panel
  Rectangle {
    anchors.fill: parent
    color: Vt.a(Vt.panel, 0.94)
    border.width: 1
    border.color: Vt.lineDim
  }
  Rectangle {   // soft outer glow (dark themes)
    anchors.fill: parent
    anchors.margins: -3
    z: -1
    color: "transparent"
    border.width: 3
    border.color: Vt.glow
  }
  BracketFrame { anchors.fill: parent; hairline: false }

  Column {
    id: col
    x: 14
    y: 14
    width: root.width - 28
    spacing: 8

    // thumbnail
    Item {
      id: thumb
      width: parent.width
      height: Math.round(width * 9 / 16)

      Rectangle { anchors.fill: parent; color: "#000000" }

      Image {
        id: imgA
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: 720
        opacity: root.aFront ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 260 } }
        onStatusChanged: {
          if (status === Image.Ready) { root.hasFrame = true; root.failed = false; if (!root.aFront) root.aFront = true }
          else if (status === Image.Error && !root.hasFrame) root.failed = true
        }
      }
      Image {
        id: imgB
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: 720
        opacity: root.aFront ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 260 } }
        onStatusChanged: {
          if (status === Image.Ready) { root.hasFrame = true; root.failed = false; if (root.aFront) root.aFront = false }
          else if (status === Image.Error && !root.hasFrame) root.failed = true
        }
      }

      // acquiring / no-signal states (shade-block noise, not a spinner)
      Text {
        anchors.centerIn: parent
        visible: !root.hasFrame
        textFormat: Text.PlainText
        text: root.failed ? "▒▒ NO SIGNAL ▒▒" : "░▒▓ ACQUIRING SIGNAL ▓▒░"
        color: Vt.accent
        font.family: Vt.mono
        font.pixelSize: Vt.fsBody
        SequentialAnimation on opacity {
          running: !root.hasFrame && !root.failed && root.visible
          loops: Animation.Infinite
          NumberAnimation { from: 1; to: 0.35; duration: 700 }
          NumberAnimation { from: 0.35; to: 1; duration: 700 }
        }
      }

      // optional CRT scanlines
      Canvas {
        anchors.fill: parent
        visible: root.scanlines
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          ctx.fillStyle = "rgba(0,0,0,0.22)"
          for (var y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1)
        }
      }

      // kind badge
      Rectangle {
        x: 8; y: 8
        width: badge.implicitWidth + 14
        height: 20
        color: Vt.a(Vt.panel, 0.82)
        border.width: 1
        border.color: Vt.line
        Text {
          id: badge
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.cam ? Vt.shade(root.cam.kind) + " " + Vt.kindWord(root.cam.kind) : ""
          color: Vt.accent
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
          font.bold: true
        }
      }

      // connecting overlay
      Rectangle {
        anchors.fill: parent
        visible: root.connecting
        color: Qt.rgba(0, 0, 0, 0.55)
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "▓▒░ CONNECTING ░▒▓"
          color: Vt.accent
          font.family: Vt.mono
          font.pixelSize: Vt.fsBody
          font.bold: true
        }
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: thumbMouse.containsMouse ? Vt.accent : Vt.lineDim
      }
      MouseArea {
        id: thumbMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.watch()
      }
      // play glyph on hover
      Text {
        anchors.centerIn: parent
        visible: thumbMouse.containsMouse && !root.connecting
        textFormat: Text.PlainText
        text: "▶"
        color: Vt.accent
        font.family: Vt.mono
        font.pixelSize: 40
        style: Text.Outline
        styleColor: "#000000"
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.cam ? root.cam.name : ""
      color: Vt.text
      font.family: Vt.mono
      font.pixelSize: Vt.fsBody
      font.bold: true
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.cam ? (root.cam.place ? root.cam.place + "  ·  " : "") + root.srcLabel : ""
      color: Vt.textDim
      font.family: Vt.mono
      font.pixelSize: Vt.fsSmall
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      visible: root.cam && root.cam.kind === "snapshot"
      text: root.cam ? "still image, refreshes about every " + Math.max(20, root.cam.refresh) + "s" : ""
      color: Vt.textFaint
      font.family: Vt.mono
      font.pixelSize: Vt.fsCaption
    }

    Row {
      spacing: 8
      VtButton {
        primary: true
        label: root.cam && root.cam.kind === "snapshot" ? "▶ OPEN" : "▶ WATCH"
        onClicked: root.watch()
      }
      VtButton {
        label: root.fav ? "★ SAVED" : "☆ FAVORITE"
        active: root.fav
        onClicked: root.toggleFav()
      }
      VtButton { label: "✕"; pad: 10; onClicked: root.closeRequested() }
    }
  }
}
