import QtQuick
import "Geo.js" as Geo

// Plans which web-mercator tiles cover the visible map and keeps TWO patches: the current one
// (`front`) and the one before it. When the view moves out of the current patch, or the zoom
// changes, the new patch loads on top while the previous one stays visible underneath it, so
// the map is never blanked back to the coarse world texture while tiles arrive: it sharpens
// progressively (previous patch -> new tiles -> whole-planet texture as the last fallback).
//
//   kind "sat"   NASA GIBS Landsat WELD (30 m)        kind "elev"  AWS Terrain Tiles
//   kind ""      off: nothing is fetched, both patches are released
Item {
  id: root

  property string kind: ""
  property string pluginDir: ""
  property string proj: "globe"
  property real w: 0
  property real h: 0
  property real lat0: 0
  property real lon0: 0
  property real ppd: 1
  property real globeR: 1

  property int front: 0
  // True when there is nothing (left) to load for the current view. Globe waits for it before it swaps
  // to this stack's map style, so switching styles while zoomed in never shows a half-loaded map.
  property bool settled: true
  readonly property var p1: root.front === 0 ? pa : pb          // current patch
  readonly property var p2: root.front === 0 ? pb : pa          // the one before it

  // Fires once per style activation when the bounded tile fetcher (bin/tiles.py) can't run.
  // Detail tiles just stop arriving in that case (fail closed) — the whole-planet texture still
  // shows underneath — but Globe surfaces it as a one-time toast rather than staying silent.
  signal helperFailed()
  property bool _reportedFailed: false

  // finest tile zoom the source has, the coarsest worth fetching (the whole-planet texture is
  // already this sharp below it), and how much coarser than 1 texel/px is fine (elevation is smooth)
  readonly property int maxZ: root.kind === "sat" ? 12 : 11
  readonly property int minZ: root.kind === "sat" ? 6 : 5
  readonly property real bias: root.kind === "sat" ? 0.35 : 0.7

  DetailLayer { id: pa; kind: root.kind; pluginDir: root.pluginDir }
  DetailLayer { id: pb; kind: root.kind; pluginDir: root.pluginDir }

  onKindChanged: { root.settled = (root.kind === ""); root._reportedFailed = false; root.request() }
  Connections {
    target: pa
    function onFetchDone() { root._fetched(pa) }
    function onHelperFailed() { root._failed() }
  }
  Connections {
    target: pb
    function onFetchDone() { root._fetched(pb) }
    function onHelperFailed() { root._failed() }
  }
  function _failed() { if (root._reportedFailed) return; root._reportedFailed = true; root.helperFailed() }
  function _fetched(layer) { if (layer === root.p1) settleTimer.restart() }
  Timer { id: settleTimer; interval: 480; repeat: false; onTriggered: root.settled = true }      // decode + the 260 ms tile fade-in
  onProjChanged: root.request()
  onWChanged: root.request()
  onHChanged: root.request()
  onLat0Changed: root.request()
  onLon0Changed: root.request()
  onPpdChanged: root.request()
  onGlobeRChanged: root.request()

  /** Ask for a re-plan; coalesced so a drag or a fly re-plans a few times a second, not per frame. */
  function request() {
    if (!planTimer.running) planTimer.start()
  }

  Timer { id: planTimer; interval: 140; repeat: false; onTriggered: root._replan() }

  function _replan() {
    if (root.kind === "" || root.w < 10 || root.h < 10) { pa.clear(); pb.clear(); root.settled = true; return }
    var view = {
      proj: root.proj, cx: root.w / 2, cy: root.h / 2, w: root.w, h: root.h,
      R: root.globeR, ppd: root.ppd, lat0: root.lat0, lon0: root.lon0,
      m: Geo.viewMatrix(root.lat0, root.lon0)
    }
    var plan = Geo.detailPlan(view, root.maxZ, root.minZ, 10, root.bias)
    if (!plan) { pa.clear(); pb.clear(); root.settled = true; return }
    if (root.p1.covers(plan.bounds, plan.z)) return               // the current patch still serves this view

    var n = Math.pow(2, plan.z)
    var fx = (view.lon0 + 180) / 360 * n - plan.x0
    fx -= Math.round(fx / n) * n                                  // nearest wrap to the patch
    var fy = Geo.mercY(view.lat0) * n - plan.y0
    var back = root.front === 0 ? pb : pa
    root.settled = false
    back.apply(plan, fx, fy)
    root.front = 1 - root.front                                   // the new patch becomes current; the old one stays beneath
  }
}
