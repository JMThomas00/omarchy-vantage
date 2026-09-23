import QtQuick
import Quickshell.Io
import "Geo.js" as Geo

// Dot-matrix world map: an orthographic globe or a flat equirectangular map,
// with the land drawn as LED-style dots (assets/land-dots.json, no polygon
// math at runtime), cameras clustered in screen space, kinetic drag, wheel
// zoom, and an animated great-circle arc when flying between cameras.
//
// Two Canvas layers: `scene` (land, graticule, pins -- repainted only when the
// view or data changes) and `overlay` (selection pulse, hover ring, arc --
// cheap, repainted every animation frame).
Item {
  id: root
  clip: true

  required property string pluginDir

  // ---- inputs
  property var cams: []
  property var camData: null
  property var favIdx: []
  property var _pyr: null
  property var visibleIdx: new Int32Array(0)
  property var favSet: ({})
  property var selectedCam: null
  readonly property string selectedId: root.selectedCam ? root.selectedCam.id : ""
  property string proj: "globe"
  property string mapStyle: "dots"          // dots | braille | blocks | ascii | vector | plotter
  property bool autoRotate: false
  property string vectorDetail: "high"      // low | medium | high | highest (VECTOR style only)
  property int rotateIdleSeconds: 30
  property bool terminator: false
  property bool crtMap: false
  property bool radar: false
  property bool showArcs: true
  property bool active: false
  // Land data is loaded on first activation, not at shell start.
  property bool everActive: false
  onActiveChanged: {
    if (root.active) {
      root.everActive = true
      root._lastTouchMs = 0            // auto-rotate starts straight away on open
    }
  }

  // ---- view state
  property real lat0: 28
  property real lon0: -60
  property real zoom: 1
  readonly property real minZoom: 0.8
  readonly property real maxZoom: (root.proj === "flat" ? 60 : 90) * (root.imageryOn && root.imagery ? 4 : 1)
  readonly property real baseR: Math.min(root.width, root.height) * 0.44
  readonly property real globeR: root.baseR * root.zoom
  readonly property real ppd: (root.width / 360) * root.zoom * 0.99

  property bool interacting: false
  property real paintMs: 0
  property var hoverCluster: null

  signal camPicked(int index)
  signal moved()
  signal userInteracted()
  signal imageryFailed(string why)
  signal detailUnavailable(string why)

  // ---- satellite / topo imagery: a whole-planet texture drawn by a GPU shader
  // beneath the `scene` canvas (see shaders/imagery.frag). The texture is loaded only
  // while its style is on. If the texture or the shader cannot load, fall back to DOTS.
  //
  // Switching styles never shows a half-loaded map: `mapStyle` is the style you asked for, `shownStyle`
  // the one on screen. A GPU style is loaded (texture + tiles for the current view) in the background,
  // and only when it is ready does the map swap to it in one clean cut.
  property string shownStyle: "dots"
  property string pending: ""
  readonly property bool imagery: root.shownStyle === "satellite" || root.shownStyle === "topo" || root.shownStyle === "contour"
  // BLOCKS is also drawn by the GPU shader (a fixed-size mosaic), so it never changes resolution as the map moves.
  readonly property bool mosaic: root.shownStyle === "blocks"
  property bool imageryBroken: false
  readonly property string effStyle: (root.imagery || root.mosaic) && root.imageryBroken ? "dots" : root.shownStyle
  readonly property bool imageryOn: (root.imagery || root.mosaic) && !root.imageryBroken
  readonly property real blockPx: 5
  function _imageryError(why) {
    if (root.imageryBroken) return
    root.imageryBroken = true
    root.imageryFailed(why)
    if (root.pending !== "") root._commit()
    root._touchScene()
  }

  function _texReady(s) {
    if (s === "satellite") return satImg.status === Image.Ready
    if (s === "topo" || s === "contour") return elevImg.status === Image.Ready
    if (s === "blocks") return maskImg.status === Image.Ready
    return true
  }
  function _stackSettled(s) {
    if (s === "satellite") return satStack.settled
    if (s === "topo" || s === "contour") return elevStack.settled
    return true
  }
  function _maybeSwitch() {
    if (root.pending !== "" && root._texReady(root.pending) && root._stackSettled(root.pending)) root._commit()
  }
  function _commit() {
    switchTimer.stop()
    var s = root.pending
    root.pending = ""
    if (s !== "") root.shownStyle = s
    root._touchScene()
  }
  function _requestStyle(s) {
    if (s === "satellite" || s === "topo" || s === "contour" || s === "blocks") {
      root.pending = s
      switchTimer.restart()
      root._maybeSwitch()
    } else {
      switchTimer.stop()
      root.pending = ""
      root.shownStyle = s
    }
  }
  Timer { id: switchTimer; interval: 1500; repeat: false; onTriggered: root._commit() }      // never wait forever (slow disk or network)
  Component.onCompleted: if (root.pending === "") root.shownStyle = root.mapStyle

  // ---- land data
  property var land: null

  FileView {
    id: landFile
    path: root.everActive ? root.pluginDir + "/assets/land-dots.json" : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      if (!d) return
      root.land = {
        sphere: { coarse: Geo.prepDots(d.sphere.coarse), mid: Geo.prepDots(d.sphere.mid), fine: Geo.prepDots(d.sphere.fine) },
        grid: { coarse: Geo.prepDots(d.grid.coarse), mid: Geo.prepDots(d.grid.mid), fine: Geo.prepDots(d.grid.fine) }
      }
      root._touchScene()
    }
  }

  // ---- vector line art, loaded only when the VECTOR style is first used.
  // Tiers are prepared (unit vectors, bounding caps) lazily the first time a detail level
  // needs them; "highest" adds a second file (finest coastline + 1:50m borders) that is only
  // read when that level is chosen.
  property var _vecRaw: null
  property var _vecMaxRaw: null
  property var _vecCache: ({})
  FileView {
    id: vectorFile
    path: root.everActive && root.mapStyle === "vector" ? root.pluginDir + "/assets/vector.json" : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      if (!d) return
      root._vecCache = ({})
      root._vecRaw = d
      root._touchScene()
    }
  }
  FileView {
    id: vectorMaxFile
    path: root.everActive && root.mapStyle === "vector" && root.vectorDetail === "highest" ? root.pluginDir + "/assets/vector-max.json" : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      if (!d) return
      root._vecMaxRaw = d
      root._touchScene()
    }
  }
  onVectorDetailChanged: root._touchScene()

  /** Prepared polylines for a tier key, or null if that data is not loaded yet. */
  function _vecLines(key) {
    var c = root._vecCache[key]
    if (c) return c
    var raw = null
    if (key === "max") raw = root._vecMaxRaw ? root._vecMaxRaw.coast.max : null
    else if (key === "bordersHi") raw = root._vecMaxRaw ? root._vecMaxRaw.borders : null
    else if (key === "borders") raw = root._vecRaw ? root._vecRaw.borders : null
    else raw = root._vecRaw ? root._vecRaw.coast[key] : null
    if (!raw) return null
    c = Geo.prepLines(raw)
    root._vecCache[key] = c
    return c
  }

  // Measures the mono font for the glyph map styles (cell = one glyph).
  FontMetrics { id: fm; font.family: Vt.mono }

  onMapStyleChanged: {
    root.imageryBroken = false
    root._requestStyle(root.mapStyle)
    root._touchScene()
    Qt.callLater(function () { root.zoom = Geo.clamp(root.zoom, root.minZoom, root.maxZoom) })   // leaving the deep-zoom styles
  }

  // ---------------------------------------------------------------- helpers

  function view() {
    return {
      proj: root.proj, cx: root.width / 2, cy: root.height / 2, w: root.width, h: root.height,
      R: root.globeR, ppd: root.ppd, lat0: root.lat0, lon0: root.lon0,
      m: Geo.viewMatrix(root.lat0, root.lon0)
    }
  }

  function _touchScene() {
    scene.requestPaint()
    overlay.requestPaint()
  }

  /** Flat map: how far the view centre may sit from the middle of the world at zoom z (degrees). Where the
   *  whole world fits inside the window along an axis the limit is 0, so that axis is locked to the centre
   *  and there is nothing to scroll; zoomed in, you can pan only as far as the map's real edges. */
  function _flatLimits(z) {
    if (root.width < 10 || root.height < 10) return { lat: 0, lon: 0 }
    var p = (root.width / 360) * z * 0.99                       // pixels per degree at that zoom
    return { lat: Math.max(0, 90 - root.height / 2 / p), lon: Math.max(0, 180 - root.width / 2 / p) }
  }

  function _clampView() {
    if (root.proj === "flat") {
      var L = root._flatLimits(root.zoom)
      root.lat0 = Geo.clamp(root.lat0, -L.lat, L.lat)
      root.lon0 = Geo.clamp(root.lon0, -L.lon, L.lon)
    } else {
      root.lat0 = Geo.clamp(root.lat0, -85, 85)
      root.lon0 = Geo.wrapLon(root.lon0)
    }
  }

  function _panBy(dx, dy) {
    if (root.proj === "flat") {
      root.lon0 -= dx / root.ppd
      root.lat0 += dy / root.ppd
    } else {
      var k = 180 / Math.PI / root.globeR
      var cosLat = Math.max(0.3, Math.cos(root.lat0 * Geo.DEG))
      root.lon0 -= dx * k / cosLat
      root.lat0 += dy * k
    }
    root._clampView()
  }

  function zoomBy(factor, sx, sy) {
    if (root._flying) { flyAnim.stop(); root._flying = false }     // the user took over: stop the fly-to
    var before = null
    if (root.proj === "flat" && sx !== undefined) before = Geo.screenToLatLon(root.view(), sx, sy)
    root.zoom = Geo.clamp(root.zoom * factor, root.minZoom, root.maxZoom)
    if (before) {
      root.lon0 = before[1] - (sx - root.width / 2) / root.ppd
      root.lat0 = before[0] + (sy - root.height / 2) / root.ppd
    }
    root._clampView()                                            // zooming out must also pull a flat view back inside the map
    root.userInteracted()
  }

  /** True while the view is zoomed in (or on its way to being): the second Esc zooms out before a third closes. */
  readonly property bool zoomedIn: (root._flying ? root._toZ : root.zoom) > 1.08

  function resetView() {
    if (root.proj === "flat") root.flyTo(0, 0, 1)               // the whole world, centred
    else root.flyTo(28, -60, 1)
  }

  // ---------------------------------------------------------------- fly-to

  property bool _flying: false
  property real _fromLat: 0
  property real _fromLon: 0
  property real _fromZ: 1
  property real _toLat: 0
  property real _toLon: 0
  property real _toZ: 1
  property real _bump: 0
  property real flyT: 0

  NumberAnimation {
    id: flyAnim
    target: root
    property: "flyT"
    from: 0
    to: 1
    duration: 1150
    easing.type: Easing.InOutCubic
    onStopped: { root._flying = false; root.interacting = false; root._touchScene() }
  }

  onFlyTChanged: {
    if (!root._flying) return
    var t = root.flyT
    root.lat0 = root._fromLat + (root._toLat - root._fromLat) * t
    root.lon0 = root.proj === "flat" ? root._fromLon + (root._toLon - root._fromLon) * t
                                      : Geo.wrapLon(root._fromLon + (root._toLon - root._fromLon) * t)
    var lz = Math.log(root._fromZ) * (1 - t) + Math.log(root._toZ) * t - root._bump * Math.sin(Math.PI * t)
    root.zoom = Geo.clamp(Math.exp(lz), root.minZoom, root.maxZoom)
    if (root.proj === "flat") root._clampView()
  }

  function flyTo(lat, lon, z) {
    kinetic.running = false
    flyAnim.stop()
    root._fromLat = root.lat0
    root._fromLon = root.lon0
    root._fromZ = root.zoom
    root._toZ = Geo.clamp(z, root.minZoom, root.maxZoom)
    if (root.proj === "flat") {
      var L = root._flatLimits(root._toZ)                        // a flat map does not wrap: go straight there, staying inside it
      root._toLat = Geo.clamp(lat, -L.lat, L.lat)
      root._toLon = Geo.clamp(lon, -L.lon, L.lon)
    } else {
      root._toLat = Geo.clamp(lat, -85, 85)
      root._toLon = root.lon0 + Geo.wrapLon(lon - root.lon0)
    }
    var dist = Geo.angularDistance(root.lat0, root.lon0, lat, lon)
    root._bump = root.proj === "flat" ? Math.min(0.5, dist * 0.3) : Math.min(0.9, dist * 0.55)
    root._flying = true
    root.interacting = true
    root.userInteracted()
    flyAnim.restart()
  }

  /** True when a point is on the visible side of the map and inside the window. */
  function _onScreen(lat, lon) {
    var q = Geo.projectLatLon(root.view(), lat, lon)
    return q[2] === 1 && q[0] > 12 && q[0] < root.width - 12 && q[1] > 12 && q[1] < root.height - 12
  }

  /** Fly to a camera and (optionally) draw the arc from where we were. The arc
   *  starts at the previous camera only while that one can be seen; if you have
   *  rotated or panned away from it, it starts from the middle of the view
   *  instead, so the arc is always drawn out of something on screen. Pass
   *  centreFallback=false to draw no arc at all when the previous camera is out of sight. */
  function focusCam(cam, z, arcFrom, centreFallback) {
    if (!cam) return
    var target = z !== undefined ? z : Math.max(root.zoom, root.proj === "flat" ? 9 : 5)
    if (root.showArcs && arcFrom) {
      var o = root._onScreen(arcFrom[0], arcFrom[1]) ? arcFrom : (centreFallback === false ? null : [root.lat0, root.lon0])
      if (o) root.startArc(o[0], o[1], cam.lat, cam.lon)
    }
    root.flyTo(cam.lat, cam.lon, target)
  }

  // ---------------------------------------------------------------- arc

  property var _arc: null
  property real arcT: 0

  NumberAnimation {
    id: arcAnim
    target: root
    property: "arcT"
    from: 0
    to: 1.7
    duration: 1900                // arcT 0..1: the head travels (1.12 s, in step with the 1.15 s camera fly); 1..1.7: fade out
    easing.type: Easing.Linear
    onStopped: { root._arc = null; overlay.requestPaint() }
  }
  onArcTChanged: overlay.requestPaint()

  function startArc(lat1, lon1, lat2, lon2) {
    var dist = Geo.angularDistance(lat1, lon1, lat2, lon2)
    if (dist < 0.004) return
    // Stop the running arc FIRST: its onStopped clears `_arc`, and animation.restart()
    // fires that signal too, which used to wipe the arc that had just been set.
    arcAnim.stop()
    root._arc = Geo.greatCircle(lat1, lon1, lat2, lon2, Math.max(24, Math.round(dist * 40)))
    arcAnim.start()
  }

  // ---------------------------------------------------------------- kinetics

  property real _velX: 0
  property real _velY: 0
  property real _lastMoveMs: 0

  FrameAnimation {
    id: kinetic
    running: false
    onTriggered: {
      var dt = frameTime
      root._panBy(root._velX * dt, root._velY * dt)
      var decay = Math.exp(-3.4 * dt)
      root._velX *= decay
      root._velY *= decay
      if (Math.abs(root._velX) + Math.abs(root._velY) < 10) {
        kinetic.running = false
        root.interacting = false
        root._touchScene()
      }
    }
  }

  // ---------------------------------------------------------------- auto-rotate (opt-in)
  //
  // A Timer, not a FrameAnimation: a FrameAnimation runs every vsync and keeps the
  // whole window re-rendering at 60 fps. Even so this is the one continuous
  // animation Vantage has, and it is NOT cheap (a Canvas repaint has a large
  // fixed cost), which is why it is off by default. Frames are ~8 fps and use the
  // coarse detail tier.
  property bool _rotating: false
  // 0 = "never interacted": rotation starts as soon as the window opens. Any
  // interaction (drag, wheel, click, fly-to, keys) stamps this, and rotation then
  // waits rotateIdleSeconds of quiet before resuming.
  property real _lastTouchMs: 0
  function touch() { root._lastTouchMs = Date.now() }
  onUserInteracted: root.touch()
  Timer { id: rotIdle; interval: 450; onTriggered: { root._rotating = false; root._touchScene() } }
  // Same 4 deg/s drift for every style, but vector strokes ~5k line vertices per frame, so it
  // steps at 5 fps (bigger steps) instead of 8 fps.
  Timer {
    id: rotor
    interval: root.effStyle === "vector" ? 200 : 125
    repeat: true
    running: root.autoRotate && root.proj === "globe" && root.active && root.visible
             && !root.interacting && !root._flying
    onTriggered: {
      if (Date.now() - root._lastTouchMs < root.rotateIdleSeconds * 1000) return
      root.lon0 = Geo.wrapLon(root.lon0 + 0.004 * rotor.interval)
      root._rotating = true
      rotIdle.restart()
    }
  }

  // Day/night shading follows the real sun, which barely moves: refresh once a minute.
  Timer { interval: 60000; repeat: true; running: root.terminator && root.active && root.visible; onTriggered: root._touchScene() }
  onTerminatorChanged: root._touchScene()

  // ---------------------------------------------------------------- repaint hooks

  onLat0Changed: root._onViewChanged()
  onLon0Changed: root._onViewChanged()
  onZoomChanged: root._onViewChanged()
  onProjChanged: { root._clampView(); root._onViewChanged() }
  onWidthChanged: { if (root.proj === "flat") root._clampView(); root._onViewChanged() }
  onHeightChanged: { if (root.proj === "flat") root._clampView(); root._onViewChanged() }
  onVisibleIdxChanged: { root._pyr = null; root._touchScene() }
  onFavSetChanged: { root._rebuildFavList(); root._touchScene() }
  onCamsChanged: { root._pyr = null; root._rebuildFavList(); root._touchScene() }
  function _rebuildFavList() {
    var out = [], fs = root.favSet
    for (var id in fs) {
      for (var i = 0; i < root.cams.length; i++) if (root.cams[i].id === id) { out.push(i); break }
    }
    root.favIdx = out
  }

  function _onViewChanged() {
    if (root.hoverCluster) root.hoverCluster = null     // cluster objects are rebuilt every paint
    root._updateSel()
    root._touchScene()
    movedTimer.restart()
  }
  Timer { id: movedTimer; interval: 260; repeat: false; onTriggered: root.moved() }

  Connections {
    target: Vt
    function onAccentChanged() { root._touchScene() }
    function onBgChanged() { root._touchScene() }
  }

  // ---------------------------------------------------------------- painting

  property var _clusters: []

  function _circle(ctx, x, y, r) { ctx.beginPath(); ctx.arc(x, y, r, 0, 6.283185) }

  function _fmtCount(n) { return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n) }

  function _paintScene(ctx) {
    var t0 = Date.now()
    var w = root.width, h = root.height
    ctx.clearRect(0, 0, w, h)
    if (w < 10 || h < 10) return
    var v = root.view()
    var dark = Vt.dark
    var globe = root.proj === "globe"

    var imagery = root.imageryOn && !root.mosaic       // the satellite-type styles paint their own disc
    var gpu = root.imageryOn                           // ...and every GPU style paints its own land
    var x0 = 0, x1 = 0, y0 = 0, y1 = 0
    if (globe) {
      _circle(ctx, v.cx, v.cy, v.R)
      if (!imagery) {
        ctx.fillStyle = Vt.a(Vt.accent, dark ? 0.035 : 0.06)
        ctx.fill()
      }
      if (dark) { _circle(ctx, v.cx, v.cy, v.R + 4); ctx.strokeStyle = Vt.a(Vt.accent, 0.10); ctx.lineWidth = 3; ctx.stroke() }
      _circle(ctx, v.cx, v.cy, v.R)
      ctx.strokeStyle = Vt.line
      ctx.lineWidth = 1.3
      ctx.stroke()
    } else {
      // flat map frame
      x0 = v.cx + (-180 - v.lon0) * v.ppd; x1 = v.cx + (180 - v.lon0) * v.ppd     // the world's real edges
      y0 = v.cy - (90 - v.lat0) * v.ppd; y1 = v.cy + (90 + v.lat0) * v.ppd
      ctx.strokeStyle = Vt.lineDim
      ctx.lineWidth = 1
      ctx.strokeRect(Math.round(x0) + 0.5, Math.round(y0) + 0.5, Math.round(x1 - x0), Math.round(y1 - y0))
    }

    // Everything the map draws (land, graticule, line art) stays inside the globe disc / flat-map frame:
    // dots, glyph cells and glow strokes near the rim would otherwise spill past the outline.
    var clipOn = true
    ctx.save()
    ctx.beginPath()
    if (globe) ctx.arc(v.cx, v.cy, v.R, 0, 6.283185)
    else ctx.rect(x0, y0, x1 - x0, y1 - y0)
    ctx.clip()
    var style = root.effStyle
    var glyph = style === "braille" || style === "ascii"
    var moving = root.interacting || root._rotating
    // VECTOR detail levels: which coastline / border tiers to draw when idle and when moving.
    // Fewer vertices = cheaper frames on old machines; HIGHEST also keeps detail while moving.
    var vplan = ({
      low:     { idle: "lo",  move: "xlo", bIdle: null,        bMove: null,      glow: false, gratMove: false },
      medium:  { idle: "mid", move: "xlo", bIdle: "borders",   bMove: null,      glow: false, gratMove: false },
      high:    { idle: "hi",  move: "lo",  bIdle: "borders",   bMove: null,      glow: true,  gratMove: false },
      highest: { idle: "max", move: "hi",  bIdle: "bordersHi", bMove: "borders", glow: true,  gratMove: true }
    })[root.vectorDetail] || { idle: "hi", move: "lo", bIdle: "borders", bMove: null, glow: true, gratMove: false }
    if (style === "plotter") Geo.drawGraticule(ctx, v, Vt.a(Vt.accent, dark ? 0.16 : 0.24), 10)
    else if (!glyph && style !== "blocks" && !(style === "vector" && moving && !vplan.gratMove)) Geo.drawGraticule(ctx, v, style === "vector" ? Vt.a(Vt.accent, dark ? 0.09 : 0.15) : Vt.graticule, 30)

    if (style === "vector") {
      // Phosphor line art: dim borders, then coastlines with a soft glow pass (glow only
      // when idle, on dark themes, and if the detail level asks for it -- a second stroke
      // is not free).
      if (root._vecRaw) {
        ctx.lineJoin = "round"
        var bKey = moving ? vplan.bMove : vplan.bIdle
        var bLines = bKey ? (root._vecLines(bKey) || root._vecLines("borders")) : null
        if (bLines) {
          Geo.tracePolylines(ctx, bLines, v)
          ctx.strokeStyle = Vt.a(Vt.accent, dark ? 0.24 : 0.32)
          ctx.lineWidth = 0.8
          ctx.stroke()
        }
        var cKey = moving ? vplan.move : vplan.idle
        var cLines = root._vecLines(cKey) || root._vecLines("hi")     // "max" falls back to "hi" until loaded
        if (cLines) {
          Geo.tracePolylines(ctx, cLines, v)
          if (dark && !moving && vplan.glow) { ctx.strokeStyle = Vt.a(Vt.accent, 0.16); ctx.lineWidth = 4.5; ctx.stroke() }
          ctx.strokeStyle = Vt.a(Vt.accent, dark ? 0.92 : 0.88)
          ctx.lineWidth = 1.2
          ctx.stroke()
        }
      }
    } else if (root.land && !gpu) {
      // Dot density tier: coarse while moving (cheap frames), fine when idle, mid
      // when fine would be packed tighter than ~4px (they wouldn't read as dots).
      var steps = globe ? { fine: 0.9, mid: 1.35, coarse: 2.0 } : { fine: 0.8, mid: 1.3, coarse: 2.0 }
      var perDeg = globe ? v.R * Geo.DEG : v.ppd
      var tier = "coarse"
      if (style === "plotter") {
        // '+' marks need room: the tier whose dot spacing is nearest ~9px (coarse while moving)
        var best = Infinity, names = moving ? ["coarse"] : ["coarse", "mid", "fine"]
        for (var ti = 0; ti < names.length; ti++) {
          var dd = Math.abs(Math.log(steps[names[ti]] * perDeg / 9))
          if (dd < best) { best = dd; tier = names[ti] }
        }
      } else if (!moving && steps.fine * perDeg >= 4.2) tier = "fine"
      else if (!moving && steps.mid * perDeg >= 4.2) tier = "mid"
      var set = (globe ? root.land.sphere : root.land.grid)[tier]
      var spacing = steps[tier] * perDeg
      if (glyph) {
        // One character cell ~ two dot pitches wide, so each cell holds a few
        // dots. Font size follows the dot pitch, which follows zoom.
        // braille runs chunkier so its 2x4 cell rhythm reads (at 1:1 it looks like DOTS)
        var pitch = Geo.clamp(spacing * (style === "braille" ? 1.3 : 1.0), 3.4, 10)
        var fpx = Math.max(8, Math.round(pitch * 2 / 0.6))
        // ASCII wants small type: ~11px at world zoom, shrinking to 7px as you zoom in
        // (finer glyphs = more detail), rather than growing with the dot pitch.
        if (style === "ascii") fpx = Math.round(Geo.clamp(11 - 1.6 * Math.log(Math.max(1, root.zoom)) / Math.LN2, 7, 11))
        if (moving) fpx = Math.round(fpx * 1.5)      // coarser glyphs while dragging/rotating: ~2x fewer cells per frame
        fm.font.pixelSize = fpx
        var cellW = fm.advanceWidth(Geo.sampleGlyph(style)), cellH = fm.height
        var res = Geo.glyphRows(style, set, v, cellW, cellH, spacing)
        ctx.font = fpx + "px \"" + Vt.mono + "\""
        ctx.textAlign = "left"
        ctx.textBaseline = "top"
        ctx.fillStyle = Vt.a(Vt.accent, style === "blocks" ? (dark ? 0.5 : 0.62) : (dark ? 0.72 : 0.84))
        for (var gr = 0; gr < res.runs.length; gr++) { var run = res.runs[gr]; ctx.fillText(run.text, run.col * cellW, run.row * cellH) }
      } else if (style === "plotter") {
        // pen-plotter: '+' marks on graph paper, with registration ticks around the edge
        var half = Geo.clamp(spacing * 0.3, 2, 6)
        Geo.drawLandPlus(ctx, set, v, half, dark
          ? [Vt.a(Vt.accent, 0.85), Vt.a(Vt.accent, 0.55), Vt.a(Vt.accent, 0.3)]
          : [Vt.a(Vt.accent, 0.9), Vt.a(Vt.accent, 0.6), Vt.a(Vt.accent, 0.36)], 1)
        if (clipOn) { ctx.restore(); clipOn = false }      // the ticks sit just outside the edge
        Geo.drawTicks(ctx, v, Vt.a(Vt.accent, dark ? 0.55 : 0.7))
      } else {
        var size = Geo.clamp(spacing * (tier === "fine" ? 0.5 : 0.46), 1.4, 7)
        if (globe) {
          Geo.drawLandGlobe(ctx, set, v, size, dark
            ? [Vt.a(Vt.accent, 0.62), Vt.a(Vt.accent, 0.38), Vt.a(Vt.accent, 0.18)]
            : [Vt.a(Vt.accent, 0.66), Vt.a(Vt.accent, 0.46), Vt.a(Vt.accent, 0.26)])
        } else {
          Geo.drawLandFlat(ctx, set, v, size, dark ? Vt.a(Vt.accent, 0.5) : Vt.a(Vt.accent, 0.6))
        }
      }
    }

    if (clipOn) ctx.restore()

    // ---- day / night: darken the side of the map the sun is not on
    if (root.terminator) {
      var sp = Geo.sunPosition(new Date()), sunVec = Geo.latLonToVec(sp.lat, sp.lon)
      var nightA = dark ? 0.44 : 0.26, deepA = dark ? 0.3 : 0.18
      for (var np = 0; np < 2; np++) {
        var elevRad = (np === 0 ? 0 : -12) * Geo.DEG
        ctx.fillStyle = Qt.rgba(0, 0, 0, np === 0 ? nightA : deepA)
        if (globe) {
          ctx.beginPath()
          Geo.nightPathGlobe(ctx, v, sunVec, elevRad)
          ctx.fill()
        } else {
          Geo.drawNightFlat(ctx, v, sp.lat, sp.lon, elevRad)
        }
      }
    }

    // ---- cameras
    if (root.camData && root._pyr === null) root._pyr = Geo.buildPyramid(root.camData, root.visibleIdx)
    var clusters = root._pyr ? Geo.clusterView(root._pyr, v, 42) : []
    root._clusters = clusters
    var acc = Vt.accent
    ctx.font = "bold 10px \"" + Vt.mono + "\""
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    var glowBudget = root.interacting ? 0 : 400
    for (var i = 0; i < clusters.length; i++) {
      var c = clusters[i], x = c.x, y = c.y
      if (c.n > 1) {
        var r = Geo.clusterRadius(c.n)
        _circle(ctx, x, y, r)
        ctx.fillStyle = Vt.a(acc, dark ? 0.16 : 0.22)
        ctx.fill()
        ctx.strokeStyle = Vt.a(acc, 0.9)
        ctx.lineWidth = 1.2
        ctx.stroke()
        if (c.fav) { _circle(ctx, x, y, r + 3.5); ctx.strokeStyle = Vt.fg; ctx.lineWidth = 1; ctx.stroke() }
        if (!root.interacting || c.n >= 100) {                  // count labels are costly canvas text: skipped for small clusters while the map moves
          ctx.fillStyle = Vt.fg
          ctx.fillText(root._fmtCount(c.n), x, y + 0.5)
        }
      } else {
        var cam = root.cams[c.rep]
        if (cam.kind === "video") {
          if (dark && glowBudget-- > 0) { _circle(ctx, x, y, 7.5); ctx.fillStyle = Vt.a(acc, 0.16); ctx.fill() }
          _circle(ctx, x, y, 3.3)
          ctx.fillStyle = acc
          ctx.fill()
        } else if (cam.kind === "loop") {
          _circle(ctx, x, y, 3.7)
          ctx.strokeStyle = acc
          ctx.lineWidth = 1.5
          ctx.stroke()
          _circle(ctx, x, y, 1.3)
          ctx.fillStyle = Vt.a(acc, 0.45)
          ctx.fill()
        } else {
          _circle(ctx, x, y, 2.1)
          ctx.fillStyle = Vt.a(acc, 0.55)
          ctx.fill()
        }
        if (c.fav) { _circle(ctx, x, y, 7.8); ctx.strokeStyle = Vt.fg; ctx.lineWidth = 1.2; ctx.stroke() }
      }
    }
    // favourites: a ring at each favourite's own position (independent of clustering)
    var fl = root.favIdx
    for (var f = 0; f < fl.length; f++) {
      var fc = root.cams[fl[f]]
      var fp = Geo.projectLatLon(v, fc.lat, fc.lon)
      if (!fp[2] || fp[0] < -10 || fp[1] < -10 || fp[0] > w + 10 || fp[1] > h + 10) continue
      _circle(ctx, fp[0], fp[1], 9)
      ctx.strokeStyle = Vt.fg
      ctx.lineWidth = 1.3
      ctx.stroke()
    }
    root.paintMs = Date.now() - t0
  }

  function _paintOverlay(ctx) {
    ctx.clearRect(0, 0, root.width, root.height)
    if (!root._arc) return
    var v = root.view(), w = root.width, h = root.height
    var pts = root._arc, n = pts.length
    var p = Math.min(1, root.arcT)
    var head = p * p * (3 - 2 * p) * (n - 1)              // smoothstep: eases in and out like the camera
    var fade = root.arcT > 1 ? Math.max(0, 1 - (root.arcT - 1) / 0.7) : 1
    var tailLen = Math.max(8, n * 0.7)
    var flat = v.proj === "flat"
    var wrapPx = 180 * root.ppd          // flat map: a bigger jump than this is the antimeridian
    var PITCH = 5                        // screen pixels between lit dots
    var budget = 900                     // hard cap on dots per frame
    var whole = Math.floor(head)
    var px = 0, py = 0, pk = 0, havePrev = false, lit = 0

    function dot(x, y, k, size) {
      if (x < -4 || y < -4 || x > w + 4 || y > h + 4) return
      var a = Math.max(0, Math.min(1, 1 - (head - k) / tailLen)) * fade
      if (a <= 0.02) return
      ctx.fillStyle = Vt.a(Vt.accent, a * 0.95)
      ctx.fillRect(x - size / 2, y - size / 2, size, size)
      lit++
    }

    // Sample the arc at each precomputed vertex (plus the fractional head) and lay
    // evenly spaced dots along the screen-space chords, so it reads as a
    // continuous curve at any zoom instead of a few far-apart specks.
    for (var i = 0; i <= whole + 1; i++) {
      var k = i > whole ? head : i
      if (i > whole && head <= whole) break
      var vec = pts[Math.min(whole, i)]
      if (i > whole) {
        var f = head - whole, nx = pts[Math.min(n - 1, whole + 1)]
        var vx = vec[0] + (nx[0] - vec[0]) * f, vy = vec[1] + (nx[1] - vec[1]) * f, vz = vec[2] + (nx[2] - vec[2]) * f
        var vl = Math.sqrt(vx * vx + vy * vy + vz * vz) || 1
        vec = [vx / vl, vy / vl, vz / vl]
      }
      var p = Geo.projectVec(v, vec, Math.sin(Math.PI * k / (n - 1)))
      if (!p[2]) { havePrev = false; continue }
      if (havePrev && !(flat && Math.abs(p[0] - px) > wrapPx)) {
        var dx = p[0] - px, dy = p[1] - py
        var off = (px < 0 && p[0] < 0) || (px > w && p[0] > w) || (py < 0 && p[1] < 0) || (py > h && p[1] > h)
        if (!off) {
          var m = Math.min(80, Math.floor(Math.sqrt(dx * dx + dy * dy) / PITCH))
          for (var j = 1; j < m; j++) dot(px + dx * j / m, py + dy * j / m, pk + (k - pk) * j / m, 3.6)
        }
      }
      dot(p[0], p[1], k, 3.6)
      px = p[0]; py = p[1]; pk = k; havePrev = true
      if (lit > budget) break
    }
    // the travelling head, brighter and a little larger
    if (root.arcT < 1 && havePrev && px > 0 && py > 0 && px < w && py < h) {
      ctx.fillStyle = Vt.a(Vt.fg, 0.95)
      ctx.fillRect(px - 2.5, py - 2.5, 5, 5)
    }
  }

  // ---- selection marker and hover ring: plain scene-graph items. A Canvas
  // repaint has a large fixed cost even for one ring, so nothing that animates
  // continuously is drawn on a Canvas.
  property real selX: 0
  property real selY: 0
  property bool selVisible: false
  function _updateSel() {
    var cam = root.selectedCam
    if (!cam) { root.selVisible = false; return }
    var q = Geo.projectLatLon(root.view(), cam.lat, cam.lon)
    root.selX = q[0]
    root.selY = q[1]
    root.selVisible = q[2] === 1
  }
  onSelectedCamChanged: root._updateSel()

  // Stepped ~11 fps pulse (fits the LED look, and keeps the window from
  // re-rendering at 60 fps just to animate one ring).
  property real pulse: 0
  Timer {
    interval: 90
    repeat: true
    running: root.selectedId !== "" && root.active && root.visible
    onTriggered: root.pulse = (root.pulse + 0.075) % 1
  }

  // Imagery layer (below the scene canvas, which draws graticule, pins and so on over it).
  // Two images so switching styles never decodes the wrong texture; only the active one is loaded.
  Image {
    id: satImg
    visible: false
    asynchronous: true
    cache: false
    mipmap: true
    smooth: true
    source: root.everActive && (root.mapStyle === "satellite" || root.shownStyle === "satellite") ? Qt.resolvedUrl(root.pluginDir + "/assets/satellite.jpg") : ""
    onStatusChanged: { if (status === Image.Error) root._imageryError("satellite texture failed to load"); root._maybeSwitch() }
  }
  Image {
    id: elevImg
    visible: false
    asynchronous: true
    cache: false
    mipmap: true
    smooth: true
    source: root.everActive && (root.mapStyle === "topo" || root.mapStyle === "contour" || root.shownStyle === "topo" || root.shownStyle === "contour") ? Qt.resolvedUrl(root.pluginDir + "/assets/elevation.webp") : ""
    onStatusChanged: { if (status === Image.Error) root._imageryError("elevation texture failed to load"); root._maybeSwitch() }
  }
  Image {
    id: maskImg
    visible: false
    asynchronous: true
    cache: false
    mipmap: false
    smooth: true
    source: root.everActive && (root.mapStyle === "blocks" || root.shownStyle === "blocks") ? Qt.resolvedUrl(root.pluginDir + "/assets/land-mask.png") : ""
    onStatusChanged: { if (status === Image.Error) root._imageryError("land mask failed to load"); root._maybeSwitch() }
  }

  // Streamed high-resolution tiles for the satellite / topo / contour styles when zoomed in. One stack per
  // kind, so the style you are switching TO can prefetch its tiles while the current one stays on screen.
  DetailStack {
    id: satStack
    pluginDir: root.pluginDir
    kind: root.imageryBroken || !(root.mapStyle === "satellite" || root.shownStyle === "satellite") ? "" : "sat"
    proj: root.proj
    w: root.width
    h: root.height
    lat0: root.lat0
    lon0: root.lon0
    ppd: root.ppd
    globeR: root.globeR
    onSettledChanged: root._maybeSwitch()
    onHelperFailed: root.detailUnavailable("satellite detail")
  }
  DetailStack {
    id: elevStack
    pluginDir: root.pluginDir
    kind: root.imageryBroken || !(root.mapStyle === "topo" || root.mapStyle === "contour" || root.shownStyle === "topo" || root.shownStyle === "contour") ? "" : "elev"
    proj: root.proj
    w: root.width
    h: root.height
    lat0: root.lat0
    lon0: root.lon0
    ppd: root.ppd
    globeR: root.globeR
    onSettledChanged: root._maybeSwitch()
    onHelperFailed: root.detailUnavailable(root.shownStyle === "contour" ? "contour detail" : "topo detail")
  }
  readonly property var activeStack: root.shownStyle === "satellite" ? satStack : elevStack

  ShaderEffect {
    id: imageryFx
    anchors.fill: parent
    property var tex: root.mosaic ? maskImg : (root.shownStyle === "satellite" ? satImg : elevImg)
    property var detail: root.activeStack.p1.texture
    property var detail2: root.activeStack.p2.texture
    readonly property Image texImage: root.mosaic ? maskImg : (root.shownStyle === "satellite" ? satImg : elevImg)
    visible: root.imageryOn && texImage.status === Image.Ready
    blending: true
    fragmentShader: Qt.resolvedUrl("shaders/imagery.frag.qsb")
    property matrix4x4 vm: {
      var m = Geo.viewMatrix(root.lat0, root.lon0)
      return Qt.matrix4x4(m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0, 0, 0, 0, 1)
    }
    property vector4d geom: Qt.vector4d(root.width / 2, root.height / 2, root.globeR, root.ppd)
    property vector4d view: Qt.vector4d(root.width, root.height, root.lat0, root.lon0)
    property vector4d opts: Qt.vector4d(root.mosaic ? 3 : (root.shownStyle === "topo" ? 1 : (root.shownStyle === "contour" ? 2 : 0)), root.proj === "flat" ? 1 : 0, Vt.dark ? 1 : 0, texImage.sourceSize.width)
    property vector4d tilebox: root.activeStack.p1.box
    property vector4d pinfo: Qt.vector4d(root.activeStack.p1.on ? 1 : 0, root.activeStack.p1.texW, root.activeStack.p1.texH, root.blockPx)
    property vector4d tilebox2: root.activeStack.p2.box
    property vector4d pinfo2: Qt.vector4d(root.activeStack.p2.on ? 1 : 0, root.activeStack.p2.texW, root.activeStack.p2.texH, 0)
    property color accent: Vt.accent
    property color bg: Vt.panel
    property color fg: Vt.fg
    onStatusChanged: if (status === ShaderEffect.Error) root._imageryError("map shader failed to compile: " + log)
  }

  Canvas {
    id: scene
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    renderTarget: Canvas.FramebufferObject
    onPaint: root._paintScene(getContext("2d"))
  }

  Canvas {
    id: overlay
    anchors.fill: parent
    visible: root._arc !== null
    renderStrategy: Canvas.Cooperative
    renderTarget: Canvas.FramebufferObject
    onPaint: root._paintOverlay(getContext("2d"))
  }

  // ---- radar sweep (opt-in). A static wedge texture rotated as a scene-graph item
  // (no canvas repaint per frame) plus a small pool of ping rings on the pins the
  // beam just crossed. Runs at 10 fps.
  property real sweepAngle: 0
  property var sweepHits: []
  readonly property real sweepRadius: root.proj === "globe" ? root.globeR : Math.sqrt(root.width * root.width + root.height * root.height) / 2

  Timer {
    interval: 100
    repeat: true
    running: root.radar && root.active && root.visible
    onTriggered: {
      root.sweepAngle = (root.sweepAngle + 6) % 360
      var cl = root._clusters, cx = root.width / 2, cy = root.height / 2, r2 = root.sweepRadius * root.sweepRadius
      var hits = []
      for (var i = 0; i < cl.length && hits.length < 40; i++) {
        var dx = cl[i].x - cx, dy = cl[i].y - cy
        if (dx * dx + dy * dy > r2) continue
        var behind = ((root.sweepAngle - Math.atan2(dy, dx) * Geo.RAD) % 360 + 360) % 360
        if (behind < 26) hits.push({ x: cl[i].x, y: cl[i].y, a: 1 - behind / 26, r: cl[i].n > 1 ? Geo.clusterRadius(cl[i].n) : 5 })
      }
      root.sweepHits = hits
    }
  }

  Item {
    id: radarBeam
    visible: root.radar
    x: root.width / 2
    y: root.height / 2
    rotation: root.sweepAngle
    Canvas {
      id: wedge
      width: 512
      height: 512
      x: -256
      y: -256
      scale: Math.max(0.2, root.sweepRadius / 256)
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, 512, 512)
        var acc = Vt.accent
        // trailing wedge: 30 degrees behind the beam, fading out
        var grad = ctx.createConicalGradient(256, 256, -30 * Math.PI / 180)
        grad.addColorStop(0, Vt.a(acc, 0))
        grad.addColorStop(30 / 360, Vt.a(acc, Vt.dark ? 0.32 : 0.4))
        grad.addColorStop(1, Vt.a(acc, 0))
        ctx.fillStyle = grad
        ctx.beginPath()
        ctx.moveTo(256, 256)
        ctx.arc(256, 256, 256, -30 * Math.PI / 180, 0)
        ctx.closePath()
        ctx.fill()
        ctx.strokeStyle = Vt.a(acc, 0.85)
        ctx.lineWidth = 1.2
        ctx.beginPath()
        ctx.moveTo(256, 256)
        ctx.lineTo(512, 256)
        ctx.stroke()
      }
      Connections { target: Vt; function onAccentChanged() { wedge.requestPaint() } }
    }
  }
  Repeater {
    model: 40
    delegate: Rectangle {
      required property int index
      readonly property var hit: index < root.sweepHits.length ? root.sweepHits[index] : null
      visible: root.radar && hit !== null
      x: hit ? hit.x - width / 2 : 0
      y: hit ? hit.y - height / 2 : 0
      // sonar ping: starts just outside the pin and expands as the beam moves on
      width: hit ? 2 * (hit.r + 3 + (1 - hit.a) * 18) : 18
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 2
      border.color: hit ? Vt.a(Vt.accent, Math.min(1, hit.a * 1.1)) : "transparent"
    }
  }

  // Selected-camera marker (pulse ring + corner brackets + dot)
  Item {
    id: marker
    visible: root.selectedCam !== null && root.selVisible
    x: root.selX
    y: root.selY
    Rectangle {
      width: 16 + 28 * root.pulse
      height: width
      x: -width / 2
      y: -height / 2
      radius: width / 2
      color: "transparent"
      border.width: 1.5
      border.color: Vt.a(Vt.accent, (1 - root.pulse) * 0.8)
    }
    BracketFrame { x: -13; y: -13; width: 26; height: 26; len: 6; thickness: 2; hairline: false }
    Rectangle { x: -3.6; y: -3.6; width: 7.2; height: 7.2; radius: 3.6; color: Vt.accent }
  }

  // Hover ring
  Rectangle {
    visible: root.hoverCluster !== null && !root.interacting
    readonly property real r: root.hoverCluster ? (root.hoverCluster.n > 1 ? Geo.clusterRadius(root.hoverCluster.n) + 4 : 9) : 9
    x: root.hoverCluster ? root.hoverCluster.x - r : 0
    y: root.hoverCluster ? root.hoverCluster.y - r : 0
    width: r * 2
    height: r * 2
    radius: r
    color: "transparent"
    border.width: 1
    border.color: Vt.a(Vt.accent, 0.9)
  }

  // CRT look over the whole map: scanlines + vignette. Painted once (only on resize),
  // so it costs nothing while idle.
  Canvas {
    id: crt
    anchors.fill: parent
    visible: root.crtMap
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onPaint: {
      var ctx = getContext("2d"), w = width, h = height
      ctx.clearRect(0, 0, w, h)
      if (w < 10 || h < 10) return
      ctx.fillStyle = "rgba(0,0,0,0.20)"
      for (var y = 0; y < h; y += 3) ctx.fillRect(0, y, w, 1)
      var g = ctx.createRadialGradient(w / 2, h / 2, Math.min(w, h) * 0.35, w / 2, h / 2, Math.max(w, h) * 0.75)
      g.addColorStop(0, "rgba(0,0,0,0)")
      g.addColorStop(1, "rgba(0,0,0,0.5)")
      ctx.fillStyle = g
      ctx.fillRect(0, 0, w, h)
    }
  }

  // ---------------------------------------------------------------- input

  DragHandler {
    id: drag
    target: null
    acceptedButtons: Qt.LeftButton
    property real lastX: 0
    property real lastY: 0
    property real lastT: 0
    onActiveChanged: {
      if (active) {
        lastX = 0; lastY = 0; lastT = Date.now()
        kinetic.running = false
        flyAnim.stop()
        root._flying = false
        root._velX = 0; root._velY = 0
        root.interacting = true
        root.userInteracted()
      } else {
        var speed = Math.abs(root._velX) + Math.abs(root._velY)
        if (speed > 60 && Date.now() - lastT < 90) { kinetic.running = true }
        else { root.interacting = false; root._touchScene() }
      }
    }
    onTranslationChanged: {
      var dx = translation.x - lastX, dy = translation.y - lastY
      var now = Date.now(), dt = Math.max(1, now - lastT) / 1000
      lastX = translation.x; lastY = translation.y; lastT = now
      root._velX = 0.6 * root._velX + 0.4 * (dx / dt)
      root._velY = 0.6 * root._velY + 0.4 * (dy / dt)
      root._panBy(dx, dy)
    }
  }

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function (event) {
      root.zoomBy(Math.exp(event.angleDelta.y / 720), point.position.x, point.position.y)
    }
  }

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: function (eventPoint) {
      var c = Geo.hit(root._clusters, eventPoint.position.x, eventPoint.position.y, 11)
      root.userInteracted()
      if (!c) return
      if (c.n === 1) root.camPicked(c.rep)
      else root.flyTo(c.lat, c.lon, Math.min(root.maxZoom, root.zoom * (c.n > 40 ? 3.2 : 2.4)))
    }
  }

  HoverHandler {
    id: hover
    cursorShape: root.hoverCluster ? Qt.PointingHandCursor : Qt.ArrowCursor
    onPointChanged: {
      if (root.interacting) return
      var c = Geo.hit(root._clusters, point.position.x, point.position.y, 11)
      if (c !== root.hoverCluster) root.hoverCluster = c
      tip.px = point.position.x
      tip.py = point.position.y
    }
    onHoveredChanged: if (!hovered) root.hoverCluster = null
  }

  // Hover tooltip (monospace, bracketed)
  Rectangle {
    id: tip
    property real px: 0
    property real py: 0
    visible: root.hoverCluster !== null && !root.interacting
    x: Math.max(4, Math.min(root.width - width - 4, px + 14))
    y: Math.max(4, Math.min(root.height - height - 4, py + 16))
    width: tipText.implicitWidth + 16
    height: tipText.implicitHeight + 8
    color: Vt.panel
    border.width: 1
    border.color: Vt.line
    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      color: Vt.text
      font.family: Vt.mono
      font.pixelSize: Vt.fsSmall
      text: {
        var c = root.hoverCluster
        if (!c) return ""
        if (c.n > 1) return c.n + " cameras  ▸ click to zoom"
        var cam = root.cams[c.rep]
        return Vt.shade(cam.kind) + " " + cam.name
      }
    }
  }
}
