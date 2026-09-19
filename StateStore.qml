import QtQuick
import Quickshell
import Quickshell.Io

// ~/.local/state/vantage/state.json -- favorites, recents and settings.
// Favorites store a small snapshot of the camera (not just its id) so a cam
// that later disappears from a source still shows up, greyed out, instead of
// silently vanishing from the user's list.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/vantage"
  readonly property string path: root.stateDir + "/state.json"

  property bool loaded: false
  property var favorites: []            // [{id,name,place,lat,lon,kind,src,country,cat,stream,thumb,refresh}]
  property var favIds: ({})
  property var recent: []               // [{id, ts}]

  property string projection: "globe"   // "globe" | "flat"
  property string mapStyle: "dots"      // dots | braille | blocks | ascii | vector | plotter | satellite | topo | contour
  property bool autoRotate: false
  property string vectorDetail: "high" // low | medium | high | highest (VECTOR style)
  property int rotateIdleSeconds: 30    // quiet time after any interaction before auto-rotate resumes
  property string palette: "accent"     // accent | green | orange | yellow | cyan | blue | magenta | red
  property bool terminator: false       // day/night shading from the real sun position
  property bool crtMap: false           // scanlines + vignette over the whole map
  property bool radar: false            // rotating radar sweep that pings pins
  property bool randomOpensStream: true
  property bool showArcs: true
  property bool scanlines: false
  property int maxViewers: 4
  property int volume: 60
  property var kindOn: ({ video: true, loop: true, snapshot: true })
  // Agency streams that answered a definitive HTTP 4xx: id -> epoch ms. They are treated as
  // snapshot pins for DEAD_TTL_MS (a dead stream stays dead for days), so Random stops picking them.
  property var dead: ({})
  readonly property real deadTtlMs: 3 * 86400 * 1000

  property bool _dirReady: false
  property bool _dirty: false

  function isFav(id) { return root.favIds[id] === true }

  function toggleFavorite(cam) {
    if (!cam) return
    var next
    if (root.isFav(cam.id)) {
      next = root.favorites.filter(function (f) { return f.id !== cam.id })
    } else {
      next = root.favorites.slice()
      next.unshift({ id: cam.id, name: cam.name, place: cam.place, country: cam.country, lat: cam.lat,
        lon: cam.lon, kind: cam.kind, src: cam.src, cat: cam.cat, stream: cam.stream,
        thumb: cam.thumb, refresh: cam.refresh })
    }
    root._setFavorites(next)
  }

  function markDead(id) {
    if (typeof id !== "string" || id.length > 100) return
    var d = Object.assign({}, root.dead)
    d[id] = Date.now()
    root.dead = d
    root._scheduleSave()
  }

  function pushRecent(id) {
    var next = root.recent.filter(function (r) { return r.id !== id })
    next.unshift({ id: id, ts: Date.now() })
    root.recent = next.slice(0, 30)
    root._scheduleSave()
  }

  function clearRecent() { root.recent = []; root._scheduleSave() }

  function setSetting(key, value) {
    if (key === "kindOn") root.kindOn = value
    else root[key] = value
    root._scheduleSave()
  }

  function _setFavorites(list) {
    var ids = {}
    for (var i = 0; i < list.length; i++) ids[list[i].id] = true
    root.favIds = ids
    root.favorites = list
    root._scheduleSave()
  }

  function _scheduleSave() { root._dirty = true; saveTimer.restart() }

  function _save() {
    if (!root._dirReady) { saveTimer.restart(); return }
    root._dirty = false
    file.setText(JSON.stringify({
      v: 1, favorites: root.favorites, recent: root.recent, projection: root.projection, mapStyle: root.mapStyle, vectorDetail: root.vectorDetail, autoRotate: root.autoRotate, rotateIdleSeconds: root.rotateIdleSeconds,
      palette: root.palette, terminator: root.terminator, crtMap: root.crtMap, radar: root.radar,
      randomOpensStream: root.randomOpensStream, showArcs: root.showArcs,
      scanlines: root.scanlines, maxViewers: root.maxViewers, volume: root.volume,
      kindOn: root.kindOn, dead: root.dead
    }))
  }

  function _applyLoaded(raw) {
    if (root.loaded) return
    root.loaded = true
    var d = {}
    try { d = JSON.parse(raw || "{}") || {} } catch (e) { d = {} }
    root._setFavorites(Array.isArray(d.favorites) ? d.favorites.filter(function (f) { return f && f.id }) : [])
    root.recent = Array.isArray(d.recent) ? d.recent.slice(0, 30) : []
    root.projection = d.projection === "flat" ? "flat" : "globe"
    root.mapStyle = ["dots", "braille", "blocks", "ascii", "vector", "plotter", "satellite", "topo", "contour"].indexOf(d.mapStyle) >= 0 ? d.mapStyle : "dots"
    root.autoRotate = d.autoRotate === true
    root.vectorDetail = ["low", "medium", "high", "highest"].indexOf(d.vectorDetail) >= 0 ? d.vectorDetail : "high"
    root.rotateIdleSeconds = Math.max(5, Math.min(300, Number(d.rotateIdleSeconds) || 30))
    root.palette = ["accent", "green", "orange", "yellow", "cyan", "blue", "magenta", "red"].indexOf(d.palette) >= 0 ? d.palette : "accent"
    root.terminator = d.terminator === true
    root.crtMap = d.crtMap === true
    root.radar = d.radar === true
    root.randomOpensStream = d.randomOpensStream !== false
    root.showArcs = d.showArcs !== false
    root.scanlines = d.scanlines === true
    root.maxViewers = Math.max(1, Math.min(8, Number(d.maxViewers) || 4))
    root.volume = Math.max(0, Math.min(100, d.volume === undefined ? 60 : Number(d.volume)))
    var k = d.kindOn || {}
    var kv = { video: k.video !== false, loop: k.loop !== false, snapshot: k.snapshot !== false }
    // The UI never lets all three be off (the map would be empty); a hand-edited or corrupt file could.
    if (!kv.video && !kv.loop && !kv.snapshot) kv = { video: true, loop: true, snapshot: true }
    root.kindOn = kv
    var dd = {}, now = Date.now(), n = 0
    var raw = d.dead && typeof d.dead === "object" ? d.dead : {}
    for (var id in raw) {
      if (n >= 3000) break
      if (typeof raw[id] === "number" && now - raw[id] < root.deadTtlMs) { dd[id] = raw[id]; n++ }
    }
    root.dead = dd
    root._dirty = false
  }

  Timer { id: saveTimer; interval: 500; repeat: false; onTriggered: root._save() }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: root._dirReady = true
  }

  FileView {
    id: file
    path: root.path
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoaded(text())
    onLoadFailed: root._applyLoaded("")
  }

  Component.onCompleted: mkdirProc.running = true
  Component.onDestruction: if (root._dirty && root._dirReady) root._save()
}
