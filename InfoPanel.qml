import QtQuick
import qs.Commons

// Settings + Sources, in one overlay page. The Sources list is styled as a
// Ceefax-style numbered index page and doubles as the attribution notice the
// open-data licences ask for.
Item {
  id: root

  property var stateRef: null
  property var catalogRef: null
  signal closeRequested()
  signal rebuildRequested()

  readonly property var meta: ({
    caltrans:    { n: 101, t: "CALTRANS",           lic: "California DOT district CCTV feeds. Public data; cameras belong to Caltrans." },
    tfl:         { n: 102, t: "TFL JAMCAM",         lic: "Powered by TfL Open Data. Open Government Licence v3.0; contains OS data © Crown copyright." },
    digitraffic: { n: 103, t: "DIGITRAFFIC FI",     lic: "Source: Fintraffic / digitraffic.fi, licence CC 4.0 BY." },
    drivebc:     { n: 104, t: "DRIVEBC",            lic: "BC Ministry of Transportation and Transit. Open Government Licence - British Columbia." },
    nsw:         { n: 105, t: "LIVE TRAFFIC NSW",   lic: "Transport for NSW, Live Traffic. Creative Commons Attribution 4.0." },
    sgtraffic:   { n: 106, t: "SINGAPORE LTA",      lic: "Land Transport Authority via data.gov.sg. Singapore Open Data Licence v1.0." },
    yt:          { n: 108, t: "YOUTUBE 24/7",       lic: "Public live streams run by the cameras' own operators (EarthCam, USGS, explore.org, Africam, aquariums and more). Played through yt-dlp + mpv; no ads are injected." }
  })

  readonly property var styles: [
    { k: "dots",    t: "DOTS",    d: "LED dot-matrix: glowing squares on a lat/lon lattice." },
    { k: "braille", t: "BRAILLE", d: "Unicode braille glyphs (⣿): 2x4 sub-dots per character, the terminal-graphics look." },
    { k: "blocks",  t: "BLOCKS",  d: "Teletext-style mosaic: a fixed grid of small square blocks lit over land. Drawn on the GPU, so it stays the same size and smooth while you drag or spin." },
    { k: "ascii",   t: "ASCII",   d: "A . : - = + * # % @ density ramp with limb shading, like a classic terminal globe." },
    { k: "vector",  t: "VECTOR",  d: "Phosphor line art: glowing coastlines and borders, like a vector CRT display." },
    { k: "plotter", t: "PLOTTER", d: "Pen-plotter: + marks on graph paper, with registration ticks around the edge." },
    { k: "satellite", t: "SATELLITE", d: "True-colour satellite imagery on the GPU: NASA Blue Marble worldwide, with Landsat tiles streamed in as you zoom (down to ~30 m)." },
    { k: "topo",    t: "TOPO",    d: "Topographic map from global relief data: hillshading, contour lines and ocean depth, tinted from your theme's accent. Elevation tiles stream in as you zoom." },
    { k: "contour", t: "CONTOUR", d: "Topographic line map: thin contour lines with heavier index lines on a faint relief tint, like a USGS quad. The interval refines as you zoom." }
  ]

  readonly property var vectorLevels: [
    { k: "low",     t: "LOW",     d: "Fewest lines: simple coastlines only, no borders or glow. Lightest on old hardware (about half the CPU of HIGHEST while moving)." },
    { k: "medium",  t: "MEDIUM",  d: "Detailed coastline plus borders when still; simplified coastline while moving." },
    { k: "high",    t: "HIGH",    d: "Full 6 km coastline, borders and a phosphor glow when still. The default." },
    { k: "highest", t: "HIGHEST", d: "2 km coastline and 1:50m borders, and detail is kept while dragging or rotating. Needs a strong machine." }
  ]

  // Palette choices come from the CURRENT theme's colors.toml (see ThemePalette.qml).
  readonly property var palettes: [
    { k: "accent",  t: "THEME" }, { k: "green",  t: "GREEN" }, { k: "orange", t: "AMBER" }, { k: "yellow", t: "YELLOW" },
    { k: "cyan",    t: "CYAN" },  { k: "blue",   t: "BLUE" },  { k: "magenta", t: "MAGENTA" }, { k: "red", t: "RED" }
  ]

  function fmt(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",") }

  Rectangle { anchors.fill: parent; color: Vt.panel }
  BracketFrame { anchors.fill: parent; anchors.margins: 6; hairline: true }

  MouseArea { anchors.fill: parent; hoverEnabled: true; onWheel: function (w) { w.accepted = true } }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: 22
    contentHeight: body.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: body
      width: flick.width
      spacing: 14

      Row {
        width: parent.width
        spacing: 12
        Logo { full: true; pixelSize: 11 }
        Item { width: parent.width - 420; height: 1 }
        VtButton { label: "✕ CLOSE"; onClicked: root.closeRequested() }
      }

      Text { textFormat: Text.PlainText; text: "SETTINGS"; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsBody; font.bold: true }

      Text { textFormat: Text.PlainText; text: "MAP STYLE   ( M cycles )"; color: Vt.textDim; font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
      Flow {
        width: parent.width
        spacing: 6
        Repeater {
          model: root.styles
          delegate: VtButton {
            required property var modelData
            label: modelData.t
            active: root.stateRef && root.stateRef.mapStyle === modelData.k
            onClicked: root.stateRef.setSetting("mapStyle", modelData.k)
          }
        }
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: {
          if (!root.stateRef) return ""
          for (var i = 0; i < root.styles.length; i++) if (root.styles[i].k === root.stateRef.mapStyle) return root.styles[i].d
          return ""
        }
        color: Vt.textFaint
        font.family: Vt.mono
        font.pixelSize: Vt.fsCaption
      }

      Column {
        width: parent.width
        spacing: 6
        visible: root.stateRef && root.stateRef.mapStyle === "vector"
        Text { textFormat: Text.PlainText; text: "VECTOR DETAIL   ( how many lines to draw )"; color: Vt.textDim; font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
        Row {
          spacing: 6
          Repeater {
            model: root.vectorLevels
            delegate: VtButton {
              required property var modelData
              label: modelData.t
              active: root.stateRef && root.stateRef.vectorDetail === modelData.k
              onClicked: root.stateRef.setSetting("vectorDetail", modelData.k)
            }
          }
        }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: {
            if (!root.stateRef) return ""
            for (var i = 0; i < root.vectorLevels.length; i++) if (root.vectorLevels[i].k === root.stateRef.vectorDetail) return root.vectorLevels[i].d
            return ""
          }
          color: Vt.textFaint
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
        }
      }

      Text { textFormat: Text.PlainText; text: "PALETTE   ( named colours from the current theme )"; color: Vt.textDim; font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
      Flow {
        width: parent.width
        spacing: 6
        Repeater {
          model: root.palettes
          delegate: VtButton {
            required property var modelData
            readonly property color tone: modelData.k === "accent" ? Color.accent : (Vt.themeColors[modelData.k] || "transparent")
            label: modelData.t
            swatch: tone
            enabled2: modelData.k === "accent" || Vt.themeColors[modelData.k] !== undefined
            active: root.stateRef && root.stateRef.palette === modelData.k
            onClicked: root.stateRef.setSetting("palette", modelData.k)
          }
        }
      }

      Repeater {
        model: root.stateRef ? [
          { k: "randomOpensStream", t: "Random opens the stream directly", d: "Off: Random only flies to the camera and shows its preview." },
          { k: "autoRotate", t: "Slowly auto-rotate the idle globe", d: "Costs about 35-100% of a CPU core while the window is open (vector is heaviest). Off by default; a static globe uses ~1%." },
          { k: "terminator", t: "Day / night shading", d: "Darkens the side of the map the sun isn't on, with a twilight band. Uses the real sun position; refreshes once a minute." },
          { k: "crtMap", t: "CRT scanlines over the whole map", d: "Scanlines and a vignette. Painted once, so free while idle." },
          { k: "radar", t: "Radar sweep", d: "A rotating beam that sends a sonar ping from each pin it crosses. Runs at 10 fps: about 3-5% of a CPU core." },
          { k: "showArcs", t: "Animated connection arcs", d: "A lit arc from the previous camera when flying to a new one." },
          { k: "scanlines", t: "CRT scanlines on thumbnails", d: "Purely cosmetic." },
        ] : []
        delegate: Item {
          required property var modelData
          width: body.width
          height: 40
          Text {
            id: box
            textFormat: Text.PlainText
            text: root.stateRef[modelData.k] ? "[■]" : "[ ]"
            color: Vt.accent
            font.family: Vt.mono
            font.pixelSize: Vt.fsBody
          }
          Column {
            anchors.left: box.right; anchors.leftMargin: 12; anchors.right: parent.right
            spacing: 2
            Text { textFormat: Text.PlainText; text: modelData.t; color: Vt.text; font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
            Text { width: parent.width; textFormat: Text.PlainText; text: modelData.d; color: Vt.textFaint; font.family: Vt.mono; font.pixelSize: Vt.fsCaption; elide: Text.ElideRight }
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.stateRef.setSetting(modelData.k, !root.stateRef[modelData.k])
                        if (modelData.rebuild) root.rebuildRequested()
                      } }
        }
      }

      Row {
        spacing: 12
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: "Auto-rotate idle delay"; color: Vt.text; font.family: Vt.mono; font.pixelSize: Vt.fsSmall; width: 190 }
        VtButton { label: "−"; pad: 10; onClicked: root.stateRef.setSetting("rotateIdleSeconds", Math.max(5, root.stateRef.rotateIdleSeconds - 5)) }
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: root.stateRef ? root.stateRef.rotateIdleSeconds + "s" : ""; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsBody; font.bold: true; width: 44; horizontalAlignment: Text.AlignHCenter }
        VtButton { label: "+"; pad: 10; onClicked: root.stateRef.setSetting("rotateIdleSeconds", Math.min(300, root.stateRef.rotateIdleSeconds + 5)) }
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: "quiet time after you touch the globe"; color: Vt.textFaint; font.family: Vt.mono; font.pixelSize: Vt.fsCaption }
      }
      Row {
        spacing: 12
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: "Max floating viewers"; color: Vt.text; font.family: Vt.mono; font.pixelSize: Vt.fsSmall; width: 190 }
        VtButton { label: "−"; pad: 10; onClicked: root.stateRef.setSetting("maxViewers", Math.max(1, root.stateRef.maxViewers - 1)) }
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: root.stateRef ? String(root.stateRef.maxViewers) : ""; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsBody; font.bold: true; width: 24; horizontalAlignment: Text.AlignHCenter }
        VtButton { label: "+"; pad: 10; onClicked: root.stateRef.setSetting("maxViewers", Math.min(8, root.stateRef.maxViewers + 1)) }
      }
      Row {
        spacing: 12
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: "mpv volume"; color: Vt.text; font.family: Vt.mono; font.pixelSize: Vt.fsSmall; width: 190 }
        VtButton { label: "−"; pad: 10; onClicked: root.stateRef.setSetting("volume", Math.max(0, root.stateRef.volume - 10)) }
        Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: root.stateRef ? root.stateRef.volume + "%" : ""; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsBody; font.bold: true; width: 44; horizontalAlignment: Text.AlignHCenter }
        VtButton { label: "+"; pad: 10; onClicked: root.stateRef.setSetting("volume", Math.min(100, root.stateRef.volume + 10)) }
      }

      Row {
        spacing: 10
        VtButton { label: root.catalogRef && root.catalogRef.building ? "REFRESHING…" : "REFRESH CATALOG"; enabled2: !(root.catalogRef && root.catalogRef.building); onClicked: root.rebuildRequested() }
        VtButton { label: "CLEAR RECENT"; onClicked: root.stateRef.clearRecent() }
      }

      Rectangle { width: parent.width; height: 1; color: Vt.lineDim }

      Text { textFormat: Text.PlainText; text: "P100  SOURCES INDEX"; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsBody; font.bold: true }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: root.catalogRef && root.catalogRef.builtAt > 0
          ? "Catalog built " + Qt.formatDateTime(new Date(root.catalogRef.builtAt * 1000), "yyyy-MM-dd HH:mm") + ". Refreshes automatically after 24 hours."
          : "Showing the bundled YouTube seed. The full catalog builds on first open."
        color: Vt.textFaint
        font.family: Vt.mono
        font.pixelSize: Vt.fsCaption
      }

      Repeater {
        model: root.catalogRef ? root.catalogRef.sources : []
        delegate: Column {
          required property var modelData
          width: body.width
          spacing: 2
          readonly property var m: root.meta[modelData.id] || { n: 199, t: String(modelData.id).toUpperCase(), lic: "" }
          Row {
            spacing: 12
            Text { textFormat: Text.PlainText; text: m.n; color: Vt.textDim; font.family: Vt.mono; font.pixelSize: Vt.fsSmall }
            Text { textFormat: Text.PlainText; text: m.t; color: Vt.text; font.family: Vt.mono; font.pixelSize: Vt.fsSmall; font.bold: true; width: 190 }
            Text { textFormat: Text.PlainText; text: root.fmt(modelData.count) + " cams"; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsSmall; width: 110 }
            Text {
              textFormat: Text.PlainText
              text: modelData.status === "ok" ? "█ OK" : (modelData.status === "stale" ? "▒ STALE" : (modelData.status === "seed" ? "▒ SEED" : "░ FAIL"))
              color: modelData.status === "ok" ? Vt.accent : Vt.textDim
              font.family: Vt.mono; font.pixelSize: Vt.fsSmall
            }
          }
          Text {
            x: 36
            width: parent.width - 36
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: m.lic + (modelData.error ? "   [" + modelData.error + "]" : "")
            color: Vt.textFaint
            font.family: Vt.mono
            font.pixelSize: Vt.fsCaption
          }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Only official, publisher-intended feeds. Vantage never uses embedded players or scrapes ad-supported pages, so nothing here can inject ads. Map data: Natural Earth (public domain); Blue Marble and Landsat imagery, NASA / USGS via GIBS (public domain); global relief, NOAA NCEI (public domain); zoomed elevation, AWS Terrain Tiles (SRTM, USGS 3DEP, GMTED, ETOPO1 and others). Zooming the satellite, topo and contour styles fetches tiles from gibs.earthdata.nasa.gov and s3.amazonaws.com."
        color: Vt.textFaint
        font.family: Vt.mono
        font.pixelSize: Vt.fsCaption
        topPadding: 6
      }
    }
  }
}
