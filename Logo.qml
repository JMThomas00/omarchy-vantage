import QtQuick

// BBS-scene "logo" wordmark: gradient-shaded block lettering (█▓▒░), the
// treatment the terminal-retro style note singles out for a project's own
// name. `full` renders the 5-row block-letter form (loading / empty / about
// screens); the compact one-liner sits in the header.
Item {
  id: root
  property bool full: false
  property int pixelSize: full ? 14 : Vt.fsTitle

  // 5x5 glyphs, '#' = filled.
  readonly property var glyphs: ({
    V: ["#...#", "#...#", "#...#", ".#.#.", "..#.."],
    A: [".###.", "#...#", "#####", "#...#", "#...#"],
    N: ["#...#", "##..#", "#.#.#", "#..##", "#...#"],
    T: ["#####", "..#..", "..#..", "..#..", "..#.."],
    G: [".####", "#....", "#.###", "#...#", ".####"],
    E: ["#####", "#....", "####.", "#....", "#####"]
  })
  // Vertical shade ramp: solid at the top, fading toward the bottom.
  readonly property var ramp: ["█", "█", "▓", "▒", "░"]
  readonly property var rowAlpha: [1.0, 0.95, 0.85, 0.7, 0.55]

  function rowText(r) {
    var word = "VANTAGE", out = ""
    for (var i = 0; i < word.length; i++) {
      var g = root.glyphs[word[i]][r]
      for (var c = 0; c < g.length; c++) out += g[c] === "#" ? root.ramp[r] : " "
      out += " "
    }
    return out
  }

  implicitWidth: full ? bigCol.implicitWidth : compact.implicitWidth
  implicitHeight: full ? bigCol.implicitHeight : compact.implicitHeight

  Text {
    id: compact
    visible: !root.full
    textFormat: Text.PlainText
    text: "▓▒░ VANTAGE ░▒▓"
    color: Vt.accent
    font.family: Vt.mono
    font.pixelSize: root.pixelSize
    font.bold: true
    font.letterSpacing: 1
  }

  Column {
    id: bigCol
    visible: root.full
    Repeater {
      model: 5
      delegate: Text {
        required property int index
        textFormat: Text.PlainText
        text: root.rowText(index)
        color: Vt.a(Vt.accent, root.rowAlpha[index])
        font.family: Vt.mono
        font.pixelSize: root.pixelSize
        lineHeight: 0.92
      }
    }
  }
}
