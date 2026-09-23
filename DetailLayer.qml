import QtQuick
import Quickshell
import Quickshell.Io

// One patch of streamed web-mercator tiles, composited into ONE texture (`texture`) for the
// imagery shader. Passive: DetailStack decides what to load and when. Each tile fades in as it
// arrives (so the map sharpens smoothly instead of popping), and a tile that has not arrived, or
// does not exist, is transparent, so whatever lies beneath (the previous patch, then the
// whole-planet texture) shows through.
//
//   kind "sat"   NASA GIBS Landsat WELD true-colour annual composite (30 m, public domain)
//   kind "elev"  AWS Terrain Tiles, Terrarium-encoded elevation (open data)
//
// Tiles are fetched by bin/tiles.py (24 in parallel, into ~/.cache/vantage/tiles, so revisits are
// instant and work offline), which is the only thing that ever puts a remote URL in front of QML:
// it enforces the host allowlist, a byte cap and a timeout per tile. If it cannot run, this layer
// fails closed (no tile loads, so whatever lies beneath keeps showing) rather than letting the
// Image element fetch straight from the server with none of those limits.
Item {
  id: root

  property string kind: ""
  property string pluginDir: ""

  readonly property var texture: src
  property bool on: false
  property vector4d box: Qt.vector4d(0, 0, 1, 1)          // u0, v0, du, dv in normalised web-mercator
  property int cols: 1
  property int rows: 1
  property int tileZ: -1
  property int x0: 0
  property int y0: 0
  property var tiles: []
  readonly property real texW: root.cols * 256
  readonly property real texH: root.rows * 256

  // disk-cache state
  property var ready: ({})                        // "z:x:y" -> path relative to the cache root
  property bool failed: false                      // fetcher unavailable this load: no tiles will arrive (fail closed, not a direct fetch)
  property var _proc: null
  property int _lines: 0
  readonly property string cacheBase: "file://" + (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vantage/tiles/"

  signal fetchDone()                              // the helper finished (every tile is on disk, or known to be missing)
  signal helperFailed()                            // the bounded fetcher could not run at all; no direct-network fallback is used

  onKindChanged: root.clear()

  // Tile URLs are built and fetched only inside bin/tiles.py (see SOURCES there); this layer never
  // constructs one, so there is nothing here for an Image element to load directly from the network.

  function _stop() {
    if (root._proc) { var p = root._proc; root._proc = null; p.signal(15); p.destroy() }
  }

  function _onLine(p, line) {
    if (p !== root._proc) return                                   // an older request: ignore
    var m = /^ok ([0-9]{1,2}:[0-9]{1,8}:[0-9]{1,8}) ((?:sat|elev)\/[0-9]{1,2}\/[0-9]+_[0-9]+\.(?:jpg|png))$/.exec(String(line))
    if (!m) return
    root._lines++
    var r = Object.assign({}, root.ready)
    r[m[1]] = m[2]
    root.ready = r
  }

  function _onExit(p, code) {
    if (p !== root._proc) { p.destroy(); return }
    root._proc = null
    if (code !== 0 && root._lines === 0) { root.failed = true; root.helperFailed() }   // could not run: fail closed, no tiles this load
    p.destroy()
    root.fetchDone()
  }

  function clear() {
    root._stop()
    root.ready = ({})
    root.on = false
    root.tiles = []
    root.tileZ = -1
    root.cols = 1
    root.rows = 1
  }

  /** Load a plan ({z, x0, y0, cols, rows}). (fx, fy) is where the view centre sits in tile units
   *  relative to the patch corner, so the tiles nearest the middle of the screen are requested first. */
  function apply(plan, fx, fy) {
    var n = Math.pow(2, plan.z), list = []
    for (var r = 0; r < plan.rows; r++) {
      for (var c = 0; c < plan.cols; c++) {
        var tx = (((plan.x0 + c) % n) + n) % n
        var dx = c + 0.5 - fx, dy = r + 0.5 - fy
        list.push({ px: c * 256, py: r * 256, d: dx * dx + dy * dy, key: plan.z + ":" + tx + ":" + (plan.y0 + r) })
      }
    }
    list.sort(function (a, b) { return a.d - b.d })
    root._stop()
    root.ready = ({})
    root.failed = false
    root._lines = 0
    root.tileZ = plan.z
    root.x0 = plan.x0
    root.y0 = plan.y0
    root.cols = plan.cols
    root.rows = plan.rows
    root.box = Qt.vector4d((((plan.x0 % n) + n) % n) / n, plan.y0 / n, plan.cols / n, plan.rows / n)
    root.tiles = list
    root.on = true
    if (root.pluginDir === "") { root.failed = true; root.helperFailed(); root.fetchDone(); return }
    root._proc = procComp.createObject(root, {
      command: ["/usr/bin/python3", root.pluginDir + "/bin/tiles.py", root.kind].concat(list.map(function (t) { return t.key }))
    })
  }

  Component {
    id: procComp
    Process {
      id: tp
      property bool everStarted: false
      running: true
      stdout: SplitParser { onRead: function (line) { root._onLine(tp, line) } }
      onStarted: tp.everStarted = true
      onExited: function (code) { root._onExit(tp, code) }
      // a missing python3 emits neither started nor exited
      onRunningChanged: if (!tp.running && !tp.everStarted) Qt.callLater(function () { root._onExit(tp, 127) })
    }
  }

  Component.onDestruction: root._stop()

  /** True if the tile range (same zoom) lies inside this patch. */
  function covers(b, z) {
    return root.on && z === root.tileZ && b.x0 >= root.x0 && b.x0 + b.cols <= root.x0 + root.cols
        && b.y0 >= root.y0 && b.y0 + b.rows <= root.y0 + root.rows
  }

  // The tiles live in an off-screen grid (hidden by the ShaderEffectSource that snapshots it).
  Item {
    id: grid
    width: root.cols * 256
    height: root.rows * 256
    Repeater {
      model: root.tiles
      delegate: Image {
        required property var modelData
        x: modelData.px
        y: modelData.py
        width: 256
        height: 256
        source: root.ready[modelData.key] ? root.cacheBase + root.ready[modelData.key] : ""      // always a local cache path from tiles.py, or empty (transparent) — never a remote URL
        asynchronous: true
        cache: true
        smooth: true
        fillMode: Image.Stretch
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
      }
    }
  }

  ShaderEffectSource {
    id: src
    sourceItem: grid
    hideSource: true
    live: true
    smooth: true
    textureSize: Qt.size(Math.max(1, grid.width), Math.max(1, grid.height))
    width: 1
    height: 1
  }
}
