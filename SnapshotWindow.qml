import QtQuick
import Quickshell
import "Viewer.js" as ViewerJs

// Floating viewer for snapshot-only cameras (agency still-image feeds): the
// image refreshes on the camera's own cadence with an A/B crossfade. Carries
// the full terminal chrome (bracket frame + accent caption bar); mpv windows
// can't be styled this way, so snapshot cams get the richer treatment.
FloatingWindow {
  id: win

  property var cam: null
  property string srcLabel: ""
  property bool scanlines: false
  signal closeRequested()

  title: "Vantage snapshot: " + (win.cam ? win.cam.name : "")
  color: Vt.panel
  implicitWidth: 880
  implicitHeight: 560
  minimumSize: Qt.size(480, 320)
  visible: false
  onVisibleChanged: if (!visible) win.closeRequested()

  property bool aFront: true
  property int gen: 0
  property bool hasFrame: false
  property real updatedAt: 0
  property bool failed: false

  function _url() {
    var u = win.cam ? win.cam.thumb : ""
    if (!u || !ViewerJs.urlAllowed(u)) return ""
    return u + (u.indexOf("?") >= 0 ? "&" : "?") + "vt=" + (++win.gen)
  }
  function refresh() {
    var u = win._url()
    if (!u) return
    if (win.aFront) imgB.source = u
    else imgA.source = u
  }
  onCamChanged: { win.hasFrame = false; win.failed = false; win.aFront = true; imgB.source = ""; imgA.source = win._url() }

  Timer {
    interval: Math.max(15, win.cam ? win.cam.refresh : 60) * 1000
    running: win.visible && win.cam !== null
    repeat: true
    onTriggered: win.refresh()
  }
  Timer {   // ticks the "updated Ns ago" caption
    id: ageTick
    interval: 1000
    running: win.visible
    repeat: true
    onTriggered: win._age = win.updatedAt > 0 ? Math.round((Date.now() - win.updatedAt) / 1000) : -1
  }
  property int _age: -1

  Item {
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: win.visible = false

    Rectangle {
      id: caption
      x: 0; y: 0
      width: parent.width
      height: 32
      color: Vt.a(Vt.accent, 0.10)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        x: 14
        width: parent.width - 60
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: win.cam ? "▓ " + win.cam.name + "  ·  " + (win.cam.place || win.srcLabel) + "  ·  SNAPSHOT  ·  refresh "
                        + Math.max(15, win.cam.refresh) + "s" + (win._age >= 0 ? "  ·  " + win._age + "s ago" : "") : ""
        color: Vt.accent
        font.family: Vt.mono
        font.pixelSize: Vt.fsSmall
        font.bold: true
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "✕"
        color: Vt.accent
        font.family: Vt.mono
        font.pixelSize: Vt.fsTitle
        MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: win.visible = false }
      }
    }

    Item {
      id: stage
      anchors.left: parent.left; anchors.right: parent.right
      anchors.top: caption.bottom; anchors.bottom: parent.bottom
      anchors.margins: 12
      Rectangle { anchors.fill: parent; color: "#000000" }
      Image {
        id: imgA
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        opacity: win.aFront ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
        onStatusChanged: {
          if (status === Image.Ready) { win.hasFrame = true; win.failed = false; win.updatedAt = Date.now(); if (!win.aFront) win.aFront = true }
          else if (status === Image.Error && !win.hasFrame) win.failed = true
        }
      }
      Image {
        id: imgB
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        opacity: win.aFront ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 300 } }
        onStatusChanged: {
          if (status === Image.Ready) { win.hasFrame = true; win.failed = false; win.updatedAt = Date.now(); if (win.aFront) win.aFront = false }
          else if (status === Image.Error && !win.hasFrame) win.failed = true
        }
      }
      Text {
        anchors.centerIn: parent
        visible: !win.hasFrame
        textFormat: Text.PlainText
        text: win.failed ? "▒▒ NO SIGNAL ▒▒" : "░▒▓ ACQUIRING SIGNAL ▓▒░"
        color: Vt.accent
        font.family: Vt.mono
        font.pixelSize: Vt.fsBody
      }
      Canvas {
        anchors.fill: parent
        visible: win.scanlines
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          ctx.fillStyle = "rgba(0,0,0,0.22)"
          for (var y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1)
        }
      }
    }

    BracketFrame { anchors.fill: parent; anchors.margins: 4; hairline: true }
  }
}
