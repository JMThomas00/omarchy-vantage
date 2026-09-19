import QtQuick

// Corner-bracket frame (┌ ┐ └ ┘) drawn with thin rectangles, plus an optional
// hairline border. The teletext/NOC-panel look for the preview card and the
// snapshot window.
Item {
  id: root
  property color color: Vt.accent
  property int len: 12
  property int thickness: 2
  property bool hairline: true
  property color hairlineColor: Vt.lineDim

  Rectangle {
    anchors.fill: parent
    visible: root.hairline
    color: "transparent"
    border.width: 1
    border.color: root.hairlineColor
  }

  Repeater {
    model: [
      { ax: 0, ay: 0 }, { ax: 1, ay: 0 }, { ax: 0, ay: 1 }, { ax: 1, ay: 1 }
    ]
    delegate: Item {
      required property var modelData
      x: modelData.ax ? root.width - root.len : 0
      y: modelData.ay ? root.height - root.len : 0
      width: root.len
      height: root.len
      Rectangle {   // horizontal arm
        x: 0; width: root.len; height: root.thickness; color: root.color
        y: modelData.ay ? root.len - root.thickness : 0
      }
      Rectangle {   // vertical arm
        y: 0; height: root.len; width: root.thickness; color: root.color
        x: modelData.ax ? root.len - root.thickness : 0
      }
    }
  }
}
