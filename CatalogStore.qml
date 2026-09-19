import QtQuick
import Quickshell
import Quickshell.Io
import "Geo.js" as Geo

// Owns the camera catalog: loads ~/.local/state/vantage/catalog.json, falls
// back to the bundled curated YouTube seed on a cold start, and rebuilds the
// catalog in the background via bin/catalog-build.py. The state file lives
// OUTSIDE the plugin dir on purpose (writing inside a watched plugin dir
// hot-reloads the plugin).
Item {
  id: root

  required property string pluginDir
  // StateStore, for the optional default-off sources.
  property var stateRef: null
  // Nothing is read from disk until the panel is first opened.
  property bool active: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/vantage"
  readonly property string catalogPath: root.stateDir + "/catalog.json"
  readonly property int maxAgeSeconds: 24 * 3600

  property bool ready: false            // some catalog (seed or full) is loaded
  property bool full: false             // the full built catalog (not just the seed)
  property bool building: false
  property string lastError: ""
  property var cams: []
  property var byId: ({})
  property var xyz: new Float32Array(0)
  property var camData: null
  property var sources: []              // [{id,name,count,status,error}]
  property var srcLabels: ({})
  property var bootLog: []              // [{src,name,status,count,error}]
  property real builtAt: 0

  signal catalogChanged()

  property var _seedCams: []

  function ageSeconds() { return root.builtAt > 0 ? (Date.now() / 1000 - root.builtAt) : 1e12 }

  // Whether the on-disk catalog has been read (or found missing). The freshness
  // check must wait for this: judging "is there a catalog?" before the file has
  // finished loading triggers a needless rebuild on every first open.
  property bool loadDone: false
  /** The full catalog is loaded, or there is nothing better than the seed to wait for. */
  readonly property bool settled: root.ready && (root.full || (root.loadDone && !root.building))
  property bool _freshWanted: false

  /** Rebuild if there is no full catalog or it is older than 24h, once loading has finished. */
  function requestFresh() {
    root._freshWanted = true
    if (root.loadDone) root._checkFresh()
  }

  function _checkFresh() {
    root._freshWanted = false
    if (root.building) return
    if (!root.full || root.ageSeconds() > root.maxAgeSeconds) root.rebuild()
  }

  function _loadFinished() {
    root.loadDone = true
    if (root._freshWanted) root._checkFresh()
  }

  function rebuild() {
    if (root.building) return
    root.building = true
    root._buildStarted = false
    root.lastError = ""
    root.bootLog = []
    var args = ["/usr/bin/python3", root.pluginDir + "/bin/catalog-build.py", "--out", root.catalogPath]
    buildProc.program = args
    buildProc.running = true
  }

  function _setCatalog(cams, sources, builtAt, full) {
    var byId = {}
    var labels = {}
    for (var i = 0; i < cams.length; i++) byId[cams[i].id] = cams[i]
    for (var s = 0; s < sources.length; s++) labels[sources[s].id] = sources[s].name
    root.byId = byId
    root.srcLabels = labels
    var cd = Geo.prepCams(cams)
    root.camData = cd
    root.xyz = cd.xyz
    root.sources = sources
    root.builtAt = builtAt
    root.full = full
    root.cams = cams
    root.ready = cams.length > 0
    root.catalogChanged()
  }

  // A catalog read from disk is data, not code, but a corrupt or hand-edited file must not
  // put NaN positions into the map: keep only well-formed records.
  function _sanitize(list) {
    var kinds = { video: true, loop: true, snapshot: true }, out = []
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || typeof c.id !== "string" || typeof c.name !== "string" || !kinds[c.kind]) continue
      if (typeof c.lat !== "number" || typeof c.lon !== "number" || !isFinite(c.lat) || !isFinite(c.lon)
          || Math.abs(c.lat) > 90 || Math.abs(c.lon) > 180) continue
      if (typeof c.place !== "string") c.place = ""
      if (typeof c.refresh !== "number" || !(c.refresh > 0)) c.refresh = 60
      out.push(c)
    }
    return out
  }

  // Streams learned to be dead (definitive HTTP 4xx at play time) show as snapshot pins.
  function _applyDead(list) {
    var dead = root.stateRef ? root.stateRef.dead : null
    if (!dead) return
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c.kind === "video" && c.src !== "yt" && dead[c.id]) { c.kind = "snapshot"; c.stream = c.thumb }
    }
  }

  /** A stream just failed for good: demote it now and rebuild the derived arrays. */
  function markDead(id) {
    var c = root.byId[id]
    if (!c || c.kind !== "video" || c.src === "yt") return
    c.kind = "snapshot"
    c.stream = c.thumb
    root._setCatalog(root.cams, root.sources, root.builtAt, root.full)
  }

  function _applyCatalog(raw) {
    var doc = null
    try { doc = JSON.parse(raw) } catch (e) { doc = null }
    if (!doc || !Array.isArray(doc.cams) || doc.cams.length === 0) {
      root._applySeed()
      root._loadFinished()
      return
    }
    var good = root._sanitize(doc.cams)
    root._applyDead(good)
    if (good.length === 0) { root._applySeed(); root._loadFinished(); return }
    root._setCatalog(good, Array.isArray(doc.sources) ? doc.sources : [], Number(doc.built) || 0, true)
    root._loadFinished()
  }

  function _applySeed() {
    if (root.full || root._seedCams.length === 0) return
    root._setCatalog(root._seedCams,
      [{ id: "yt", name: "YouTube 24/7 (curated)", count: root._seedCams.length, status: "seed" }], 0, false)
  }

  function _parseSeed(raw) {
    var doc = null
    try { doc = JSON.parse(raw) } catch (e) { doc = null }
    var out = []
    var list = doc && Array.isArray(doc.cams) ? doc.cams : []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!e.ytId) continue
      out.push({
        id: "yt:" + e.slug, name: e.name, place: e.place || "", country: e.country || "",
        lat: e.lat, lon: e.lon, kind: "video", src: "yt", cat: e.cat || "city",
        stream: "https://www.youtube.com/watch?v=" + e.ytId,
        thumb: "https://i.ytimg.com/vi/" + e.ytId + "/mqdefault_live.jpg", refresh: 60
      })
    }
    root._seedCams = out
    if (!root.ready) root._applySeed()
  }

  function _onBuildLine(line) {
    var ev = null
    try { ev = JSON.parse(line) } catch (e) { return }
    if (!ev || ev.ev !== "source") return
    var next = root.bootLog.filter(function (l) { return l.src !== ev.src })
    next.push({ src: ev.src, name: ev.name || ev.src, status: ev.status, count: ev.count || 0, error: ev.error || "" })
    root.bootLog = next
  }

  function _onBuildExit(code) {
    root.building = false
    if (code === 0) catalogFile.reload()
    else root.lastError = "catalog build failed (exit " + code + ")"
  }

  FileView {
    id: catalogFile
    path: root.active ? root.catalogPath : ""
    watchChanges: false
    printErrors: false
    onLoaded: root._applyCatalog(text())
    onLoadFailed: { root._applySeed(); root._loadFinished() }
  }

  FileView {
    id: seedFile
    path: root.active ? root.pluginDir + "/data/curated.json" : ""
    watchChanges: false
    printErrors: false
    onLoaded: root._parseSeed(text())
  }

  // A helper that cannot be started (python3 missing) emits neither started nor exited, so
  // `building` would stay true forever and no rebuild would ever be attempted again.
  property bool _buildStarted: false
  Connections {
    target: buildProc
    function onStarted() { root._buildStarted = true }
    function onRunningChanged() {
      if (!buildProc.running && root.building && !root._buildStarted) {
        root.building = false
        root.lastError = "could not start python3 to build the camera catalog"
      }
    }
  }

  SupervisedProcess {
    id: buildProc
    deadlineSeconds: 240
    stdout: SplitParser {
      onRead: function (line) { root._onBuildLine(line) }
    }
    onExited: function (code) { root._onBuildExit(code) }
  }
}
