pragma Singleton
import QtQuick
import qs.Commons

// Visual tokens for the terminal-retro look (see the "Terminal Retro Design
// Styles" note): ONE accent hue carries every border, glow, pin and active
// fill; everything else is foreground/background at varying alpha. Variation
// is encoded by brightness, shape and shade-block density, never by extra hues.
QtObject {
  // The accent every bit of chrome is drawn in. "accent" follows the theme's accent; any other
  // key (green, orange, cyan, ...) picks that named colour from the CURRENT theme's colors.toml
  // (themeColors, filled by ThemePalette.qml), so a "phosphor green" or "amber" palette still
  // belongs to the active theme rather than being a hard-coded hex.
  property string palette: "accent"
  property var themeColors: ({})
  readonly property color accent: (palette !== "accent" && themeColors[palette]) ? themeColors[palette] : Color.accent
  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color muted: Color.muted

  readonly property real _lum: 0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b
  // Light themes drop the glow and use solid dark dots/borders.
  readonly property bool dark: _lum < 0.5

  function a(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }

  // Near-black panel derived from the theme background.
  readonly property color panel: dark ? Qt.darker(bg, 1.5) : Qt.darker(bg, 1.04)
  readonly property color card: dark ? Qt.lighter(panel, 1.35) : Qt.darker(bg, 1.1)
  readonly property color line: a(accent, dark ? 0.6 : 0.85)
  readonly property color lineDim: a(accent, dark ? 0.24 : 0.35)
  readonly property color glow: a(accent, dark ? 0.22 : 0.0)
  readonly property color text: fg
  readonly property color textDim: a(fg, 0.62)
  readonly property color textFaint: a(fg, 0.38)
  // Land dots: dim so pins pop.
  readonly property color land: a(accent, dark ? 0.30 : 0.40)
  readonly property color landFine: a(accent, dark ? 0.42 : 0.5)
  readonly property color graticule: a(accent, dark ? 0.10 : 0.16)

  readonly property string mono: Style.font.family
  readonly property int fsCaption: Style.font.caption
  readonly property int fsSmall: Style.font.bodySmall
  readonly property int fsBody: Style.font.body
  readonly property int fsTitle: Style.font.title

  // Shade-block encoding of camera kind (density = kind, still one hue).
  function shade(kind) { return kind === "video" ? "█" : (kind === "loop" ? "▒" : "░") }
  function kindLabel(kind) { return kind === "video" ? "LIVE" : (kind === "loop" ? "LOOP" : "SNAP") }
  function kindWord(kind) { return kind === "video" ? "LIVE VIDEO" : (kind === "loop" ? "LOOP CLIP" : "SNAPSHOT") }
}
