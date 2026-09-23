import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "Search.js" as Search
import "Geo.js" as Geo

// Vantage panel root. The shell summons this via
//   omarchy-shell shell toggle|summon|hide jmthomas00.vantage
// and calls open(payloadJson) / close() on it.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  readonly property int preferredWidth: 1240
  readonly property int preferredHeight: 780
  // Sidebar scales with the window: 372px normally, down to 300px at the 900px minimum.
  readonly property int sidebarWidth: Math.round(Math.max(300, Math.min(372, panel.width * 0.34)))
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")

  property bool ruleReady: false
  property string pendingPayload: ""
  property var pendingAction: null

  property var selectedCam: null
  property string tab: "world"
  property string toastText: ""
  property var _randomHistory: []

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    if (!root.ruleReady) { root.pendingPayload = payloadJson || "{}"; return }
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    catalog.active = true
    root.opened = true
    panel.visible = true
    catalog.requestFresh()
    if (payload.action) {
      // Wait for the full catalog: the bundled seed loads first and only knows
      // the curated YouTube cams.
      root.pendingAction = payload
      Qt.callLater(root._tryPending)
    }
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    panel.visible = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "jmthomas00.vantage")
  }

  Process {
    id: ruleProc
    command: [root.pluginDir + "/bin/window-rule.sh", String(root.preferredWidth), String(root.preferredHeight)]
    onExited: function (code) {
      root.ruleReady = true
      if (root.pendingPayload) { var p = root.pendingPayload; root.pendingPayload = ""; root.open(p) }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (String(event && event.name || "") === "configreloaded") ruleReload.restart()
    }
  }
  Timer { id: ruleReload; interval: 150; onTriggered: { root.ruleReady = false; ruleProc.running = true } }

  Component.onCompleted: ruleProc.running = true

  // ---------------------------------------------------------------- stores

  StateStore { id: store }
  // Palette: named colours from the current theme feed Vt.accent when a non-theme palette is chosen.
  ThemePalette { id: themePalette; active: panel.visible }
  Binding { target: Vt; property: "themeColors"; value: themePalette.colors }
  Binding { target: Vt; property: "palette"; value: store.palette }
  CatalogStore { id: catalog; pluginDir: root.pluginDir; stateRef: store }
  Viewer {
    id: viewer
    stateRef: store
    srcLabels: catalog.srcLabels
    onToast: function (message) { root.showToast(message) }
    onStreamDead: function (id) { store.markDead(id); catalog.markDead(id) }
  }

  Connections {
    target: catalog
    function onCatalogChanged() {
      root.recomputeVisible()
      root.recomputeRows()
      root._tryPending()
    }
  }
  Connections {
    target: catalog
    function onBuildingChanged() { root._tryPending() }
    function onLoadDoneChanged() { root._tryPending() }
  }
  Connections {
    target: store
    function onKindOnChanged() { root.recomputeVisible(); root.recomputeRows() }
    function onFavoritesChanged() { if (root.tab === "favorites") root.recomputeRows() }
    function onRecentChanged() { if (root.tab === "recent") root.recomputeRows() }
    function onLoadedChanged() { root.recomputeVisible() }
  }

  function showToast(msg) { root.toastText = msg; toastTimer.restart() }
  Timer { id: toastTimer; interval: 5200; onTriggered: root.toastText = "" }

  // ---------------------------------------------------------------- data flow

  function recomputeVisible() {
    var cams = catalog.cams, kinds = store.kindOn, idx = []
    for (var i = 0; i < cams.length; i++) if (kinds[cams[i].kind]) idx.push(i)
    globe.visibleIdx = new Int32Array(idx)
  }

  function _kindFiltered() {
    var cams = catalog.cams, kinds = store.kindOn, out = []
    for (var i = 0; i < cams.length; i++) if (kinds[cams[i].kind]) out.push(cams[i])
    return out
  }

  function _nearest(limit) {
    var idx = globe.visibleIdx, xyz = catalog.xyz, cams = catalog.cams
    var v = Geo.latLonToVec(globe.lat0, globe.lon0), scored = []
    for (var q = 0; q < idx.length; q++) {
      var i = idx[q]
      scored.push([xyz[i * 3] * v[0] + xyz[i * 3 + 1] * v[1] + xyz[i * 3 + 2] * v[2], i])
    }
    scored.sort(function (a, b) { return b[0] - a[0] })
    var out = []
    for (var j = 0; j < scored.length && j < limit; j++) out.push(cams[scored[j][1]])
    return out
  }

  function recomputeRows() {
    var q = search.text.trim()
    var rows = [], heading = "", empty = ""
    if (q) {
      rows = Search.rank(root._kindFiltered(), q, catalog.srcLabels, 300)
      heading = rows.length + (rows.length >= 300 ? "+" : "") + " MATCHES FOR \"" + q.toUpperCase() + "\""
      empty = "No cameras match \"" + q + "\".\nTry a place, a road, or a name."
    } else if (root.tab === "favorites") {
      for (var f = 0; f < store.favorites.length; f++) {
        var fav = store.favorites[f], live = catalog.byId[fav.id]
        rows.push(live ? live : Object.assign({ unavailable: true }, fav))
      }
      heading = rows.length + " FAVORITES"
      empty = "No favorites yet.\nClick ☆ on a preview or a list row to save a camera."
    } else if (root.tab === "recent") {
      for (var r = 0; r < store.recent.length; r++) {
        var cam = catalog.byId[store.recent[r].id]
        if (cam) rows.push(cam)
      }
      heading = rows.length + " RECENTLY WATCHED"
      empty = "Nothing watched yet.\nOpen a camera and it will appear here."
    } else {
      rows = catalog.ready ? root._nearest(300) : []
      heading = "NEAREST TO VIEW CENTER"
      empty = catalog.ready ? "No cameras match the current filters." : "Loading catalog …"
    }
    sidebar.heading = heading
    sidebar.emptyText = empty
    sidebar.rows = rows
  }

  Timer { id: rowsTimer; interval: 140; onTriggered: root.recomputeRows() }

  // ---------------------------------------------------------------- actions

  function _fmtDeg(v, pos, neg) { return Math.abs(v).toFixed(1) + "°" + (v >= 0 ? pos : neg) }
  function _pad(s, n) { s = String(s); while (s.length < n) s += " "; return s }

  function selectCam(cam, how) {
    if (!cam) return
    var prev = root.selectedCam
    root.selectedCam = cam
    var z
    if (how === "map") z = Math.max(globe.zoom, 1.8)
    else z = Math.max(globe.zoom, globe.proj === "flat" ? 10 : 6)
    // A pin click arcs only from a previous camera you can still see; every other
    // route (list, search, Random) falls back to the middle of the view.
    var from = prev ? [prev.lat, prev.lon] : (how === "map" ? null : [globe.lat0, globe.lon0])
    globe.focusCam(cam, z, from, how !== "map")
  }

  function watch(cam) {
    if (!cam) return
    viewer.open(cam)
    store.pushRecent(cam.id)
  }

  function toggleFav(cam) { if (cam) store.toggleFavorite(cam) }

  function toggleKind(k) {
    var next = Object.assign({}, store.kindOn)
    next[k] = !next[k]
    if (!next.video && !next.loop && !next.snapshot) return
    store.setSetting("kindOn", next)
  }

  function randomCam() {
    if (!catalog.ready) return
    var cams = catalog.cams, kinds = store.kindOn, hasVideo = false, i
    if (kinds.video) for (i = 0; i < cams.length; i++) if (cams[i].kind === "video") { hasVideo = true; break }
    // Live video when it's enabled (the point of "a stream"), else whatever kinds are on.
    // Pick the SOURCE first, then a camera within it, so a 2,000-cam freeway
    // feed doesn't drown out the curated world cams.
    var bySrc = {}
    for (i = 0; i < cams.length; i++) {
      var c = cams[i]
      if (!kinds[c.kind]) continue
      if (hasVideo && c.kind !== "video") continue
      if (!bySrc[c.src]) bySrc[c.src] = []
      bySrc[c.src].push(c)
    }
    var srcs = Object.keys(bySrc)
    if (!srcs.length) { root.showToast("No cameras match the current filters."); return }
    var pick = null
    for (var attempt = 0; attempt < 8; attempt++) {
      var list = bySrc[srcs[Math.floor(Math.random() * srcs.length)]]
      pick = list[Math.floor(Math.random() * list.length)]
      if (root._randomHistory.indexOf(pick.id) < 0) break
    }
    root._randomHistory = root._randomHistory.concat([pick.id]).slice(-8)
    root.selectCam(pick, "random")
    if (store.randomOpensStream) root.watch(pick)
  }

  // Actions arriving via `omarchy-shell shell summon jmthomas00.vantage '<json>'`:
  //   {"action":"random"}
  //   {"action":"select"|"watch","id":"<camera id>","zoom":<optional number>}
  // Validated setter for scripting: {"action":"set","key":"palette","value":"green"}
  function _setSetting(key, value) {
    var bools = ["autoRotate", "terminator", "crtMap", "radar", "scanlines", "showArcs", "randomOpensStream"]
    var palettes = ["accent", "green", "orange", "yellow", "cyan", "blue", "magenta", "red"]
    if (bools.indexOf(key) >= 0 && typeof value === "boolean") store.setSetting(key, value)
    else if (key === "mapStyle" && root.styleOrder.indexOf(value) >= 0) store.setSetting(key, value)
    else if (key === "palette" && palettes.indexOf(value) >= 0) store.setSetting(key, value)
    else if (key === "vectorDetail" && ["low", "medium", "high", "highest"].indexOf(value) >= 0) store.setSetting(key, value)
    else if (key === "rotateIdleSeconds" && typeof value === "number") store.setSetting(key, Math.max(5, Math.min(300, Math.round(value))))
  }

  function _tryPending() {
    if (!root.pendingAction || !catalog.settled) return
    var a = root.pendingAction
    root.pendingAction = null
    root._runAction(a)
  }

  function _runAction(a) {
    if (a.action === "random") { root.randomCam(); return }
    if (a.action === "settings") { info.visible = true; return }
    if (a.action === "set") { root._setSetting(a.key, a.value); return }
    if (a.action === "view") {                                   // {"action":"view","lat":24,"lon":-105,"zoom":1}
      var vla = Number(a.lat), vlo = Number(a.lon), vz = Number(a.zoom)
      if (isFinite(vla) && isFinite(vlo) && vla >= -90 && vla <= 90 && vlo >= -180 && vlo <= 180)
        globe.flyTo(vla, vlo, vz > 0 ? vz : globe.zoom)
      return
    }
    if (a.action === "rotate") { store.setSetting("autoRotate", a.value === true); return }
    if (a.action === "style" && root.styleOrder.indexOf(a.value) >= 0) { store.setSetting("mapStyle", a.value); return }
    if ((a.action === "select" || a.action === "watch") && typeof a.id === "string" && a.id.length < 200) {
      var cam = catalog.byId[a.id]
      if (!cam) { root.showToast("Unknown camera: " + a.id); return }
      var z = Number(a.zoom)
      if (z > 0) {
        var prev = root.selectedCam
        root.selectedCam = cam
        globe.focusCam(cam, z, prev ? [prev.lat, prev.lon] : [globe.lat0, globe.lon0])
      } else {
        root.selectCam(cam, "search")
      }
      if (a.action === "watch") root.watch(cam)
    }
  }

  readonly property var styleOrder: ["dots", "braille", "blocks", "ascii", "vector", "plotter", "satellite", "topo", "contour"]

  function cycleStyle() {
    var i = root.styleOrder.indexOf(store.mapStyle)
    var next = root.styleOrder[(i + 1) % root.styleOrder.length]
    store.setSetting("mapStyle", next)
    root.showToast("Map style: " + next.toUpperCase())
  }

  function handleEscape() {
    if (info.visible) { info.visible = false; return }
    if (search.activeFocus || search.text !== "") { search.text = ""; keys.forceActiveFocus(); return }
    if (root.selectedCam) { root.selectedCam = null; return }
    if (globe.zoomedIn) { globe.resetView(); return }              // same as the home button
    root.dismiss()
  }

  function pickFirstResult() {
    if (sidebar.rows.length > 0) root.selectCam(sidebar.rows[0], "search")
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: panel
    visible: false
    title: "Vantage"
    color: Vt.panel
    implicitWidth: root.preferredWidth
    implicitHeight: root.preferredHeight
    minimumSize: Qt.size(900, 560)
    onVisibleChanged: if (!visible && root.opened) root.dismiss()

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.AfterItem
      Keys.onPressed: function (event) {
        globe.touch()
        if (event.key === Qt.Key_Escape) { root.handleEscape(); event.accepted = true; return }
        if (info.visible) { if (event.key === Qt.Key_S) { info.visible = false; event.accepted = true } return }
        switch (event.key) {
        case Qt.Key_Home: globe.resetView(); event.accepted = true; break
        case Qt.Key_Slash: search.forceActiveFocus(); event.accepted = true; break
        case Qt.Key_R: root.randomCam(); event.accepted = true; break
        case Qt.Key_F: if (root.selectedCam) root.toggleFav(root.selectedCam); event.accepted = true; break
        case Qt.Key_G: store.setSetting("projection", store.projection === "globe" ? "flat" : "globe"); event.accepted = true; break
        case Qt.Key_M: root.cycleStyle(); event.accepted = true; break
        case Qt.Key_S: info.visible = true; event.accepted = true; break
        case Qt.Key_Plus: case Qt.Key_Equal: globe.zoomBy(1.4); event.accepted = true; break
        case Qt.Key_Minus: globe.zoomBy(1 / 1.4); event.accepted = true; break
        case Qt.Key_Return: case Qt.Key_Enter: if (root.selectedCam) root.watch(root.selectedCam); event.accepted = true; break
        }
      }

      Rectangle { anchors.fill: parent; color: Vt.panel }

      // ------------------------------------------------------------ header
      Item {
        id: header
        x: 0; y: 0
        width: parent.width
        height: 52

        Logo { id: logo; x: 20; anchors.verticalCenter: parent.verticalCenter }

        Rectangle {
          id: searchBox
          x: logo.x + logo.width + 34
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(200, Math.min(420, header.width - x - 520))
          height: 30
          color: search.activeFocus ? Vt.a(Vt.accent, 0.12) : "transparent"
          border.width: 1
          border.color: search.activeFocus ? Vt.line : Vt.lineDim
          Text {
            id: prompt
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "▸"
            color: Vt.accent
            font.family: Vt.mono
            font.pixelSize: Vt.fsBody
          }
          TextInput {
            id: search
            anchors.left: prompt.right; anchors.leftMargin: 8
            anchors.right: clearBtn.left; anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            color: Vt.text
            selectionColor: Vt.accent
            selectedTextColor: Vt.panel
            font.family: Vt.mono
            font.pixelSize: Vt.fsBody
            clip: true
            selectByMouse: true
            onTextChanged: { rowsTimer.restart(); globe.touch() }
            Keys.onEscapePressed: root.handleEscape()
            Keys.onReturnPressed: root.pickFirstResult()
            Keys.onEnterPressed: root.pickFirstResult()
            Text {
              visible: search.text === "" && !search.activeFocus
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "search places, roads or camera names   ( / )"
              color: Vt.textFaint
              font.family: Vt.mono
              font.pixelSize: Vt.fsSmall
            }
          }
          Text {
            id: clearBtn
            anchors.right: parent.right; anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: search.text !== ""
            textFormat: Text.PlainText
            text: "✕"
            color: Vt.accent
            font.family: Vt.mono
            font.pixelSize: Vt.fsBody
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
                        onClicked: { search.text = ""; keys.forceActiveFocus() } }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Row {
            spacing: -1
            VtButton { label: "GLOBE"; active: store.projection === "globe"; onClicked: store.setSetting("projection", "globe") }
            VtButton { label: "FLAT"; active: store.projection === "flat"; onClicked: store.setSetting("projection", "flat") }
          }
          VtButton { label: "  RANDOM"; primary: true; onClicked: root.randomCam() }
          VtButton { label: ""; pad: 11; active: info.visible; onClicked: info.visible = !info.visible }
          VtButton { label: "✕"; pad: 11; onClicked: root.dismiss() }
        }

        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Vt.lineDim }
      }

      // ------------------------------------------------------------ body
      Item {
        id: body
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right

        Globe {
          id: globe
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width - root.sidebarWidth
          pluginDir: root.pluginDir
          cams: catalog.cams
          camData: catalog.camData
          favSet: store.favIds
          selectedCam: root.selectedCam
          proj: store.projection
          mapStyle: store.mapStyle
          autoRotate: store.autoRotate
          vectorDetail: store.vectorDetail
          rotateIdleSeconds: store.rotateIdleSeconds
          terminator: store.terminator
          crtMap: store.crtMap
          radar: store.radar
          showArcs: store.showArcs
          active: panel.visible
          onCamPicked: function (index) { root.selectCam(catalog.cams[index], "map") }
          onImageryFailed: function (why) { root.showToast("Map imagery unavailable (" + why + "), using DOTS") }
          onDetailUnavailable: function (why) { root.showToast(why.toUpperCase() + " tiles unavailable (helper could not run); showing base resolution") }
          onMoved: if (root.tab === "world" && search.text === "") rowsTimer.restart()
          onUserInteracted: if (!search.activeFocus) keys.forceActiveFocus()
        }

        // HUD readout, top-left
        Text {
          x: 16; y: 12
          textFormat: Text.PlainText
          text: (globe.proj === "flat" ? "FLAT MAP" : "GLOBE") + "   LAT " + root._fmtDeg(globe.lat0, "N", "S")
                + "   LON " + root._fmtDeg(globe.lon0, "E", "W") + "   ZOOM " + globe.zoom.toFixed(1) + "×"
          color: Vt.textDim
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
          style: Text.Outline
          styleColor: Vt.panel
        }
        Text {
          x: 16; y: 30
          textFormat: Text.PlainText
          text: "drag ▸ rotate    wheel ▸ zoom    click a pin ▸ preview"
          color: Vt.textFaint
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
          style: Text.Outline
          styleColor: Vt.panel
        }

        // zoom controls, bottom-right of the globe pane
        Row {
          anchors.right: globe.right
          anchors.rightMargin: 16
          anchors.bottom: globe.bottom
          anchors.bottomMargin: 14
          spacing: 6
          VtButton { label: "+"; pad: 11; onClicked: globe.zoomBy(1.5) }
          VtButton { label: "−"; pad: 11; onClicked: globe.zoomBy(1 / 1.5) }
          VtButton { label: "⌂"; pad: 11; onClicked: globe.resetView() }
        }

        // preview card, bottom-left
        PreviewCard {
          id: preview
          x: 16
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 14
          cam: root.selectedCam
          fav: root.selectedCam ? store.favIds[root.selectedCam.id] === true : false
          connecting: root.selectedCam ? viewer.connecting[root.selectedCam.id] === true : false
          srcLabel: root.selectedCam ? (catalog.srcLabels[root.selectedCam.src] || root.selectedCam.src) : ""
          scanlines: store.scanlines
          maxWidth: globe.width - 200
          running: panel.visible
          onWatch: root.watch(root.selectedCam)
          onToggleFav: root.toggleFav(root.selectedCam)
          onCloseRequested: root.selectedCam = null
        }

        Sidebar {
          id: sidebar
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: root.sidebarWidth
          tab: root.tab
          kindOn: store.kindOn
          favSet: store.favIds
          selectedId: root.selectedCam ? root.selectedCam.id : ""
          onTabPicked: function (t) { root.tab = t; search.text = ""; root.recomputeRows() }
          onKindToggled: function (k) { root.toggleKind(k) }
          onCamClicked: function (cam) { root.selectCam(cam, "list") }
          onFavClicked: function (cam) { root.toggleFav(cam) }
        }

        // first-run / no-data screen: full wordmark + boot log
        Rectangle {
          id: boot
          anchors.left: globe.left; anchors.top: globe.top; anchors.bottom: globe.bottom
          width: globe.width
          visible: !catalog.ready
          color: Vt.panel
          z: 5
          Column {
            anchors.centerIn: parent
            spacing: 22
            Logo { full: true; anchors.horizontalCenter: parent.horizontalCenter }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: catalog.lastError !== "" ? "▒▒ " + catalog.lastError + " ▒▒" : "░▒▓ BUILDING CAMERA CATALOG ▓▒░"
              color: Vt.accent
              font.family: Vt.mono
              font.pixelSize: Vt.fsBody
            }
            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 3
              Repeater {
                model: catalog.bootLog
                delegate: Text {
                  required property var modelData
                  textFormat: Text.PlainText
                  text: (modelData.status === "ok" ? "[ OK ] " : "[FAIL] ") + root._pad(modelData.src, 12)
                        + (modelData.status === "ok" ? modelData.count + " cams" : modelData.error)
                  color: modelData.status === "ok" ? Vt.accent : Vt.textDim
                  font.family: Vt.mono
                  font.pixelSize: Vt.fsSmall
                }
              }
            }
            VtButton {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: catalog.lastError !== "" && !catalog.building
              label: "RETRY"
              onClicked: catalog.rebuild()
            }
          }
        }

        // background-refresh boot log (small, non-blocking)
        Rectangle {
          anchors.right: globe.right; anchors.rightMargin: 16
          anchors.top: globe.top; anchors.topMargin: 12
          visible: catalog.ready && catalog.building
          width: refreshCol.implicitWidth + 24
          height: refreshCol.implicitHeight + 16
          color: Vt.a(Vt.panel, 0.92)
          border.width: 1
          border.color: Vt.lineDim
          z: 4
          Column {
            id: refreshCol
            x: 12; y: 8
            spacing: 2
            Text { textFormat: Text.PlainText; text: "░▒▓ REFRESHING CATALOG"; color: Vt.accent; font.family: Vt.mono; font.pixelSize: Vt.fsCaption; font.bold: true }
            Repeater {
              model: catalog.bootLog
              delegate: Text {
                required property var modelData
                textFormat: Text.PlainText
                text: (modelData.status === "ok" ? "[ OK ] " : "[FAIL] ") + root._pad(modelData.src, 12)
                      + (modelData.status === "ok" ? modelData.count : "err")
                color: modelData.status === "ok" ? Vt.textDim : Vt.textFaint
                font.family: Vt.mono
                font.pixelSize: Vt.fsCaption
              }
            }
          }
        }

        // toast
        Rectangle {
          anchors.horizontalCenter: globe.horizontalCenter
          anchors.top: globe.top
          anchors.topMargin: 12
          visible: root.toastText !== ""
          width: Math.min(globe.width - 40, toastLabel.implicitWidth + 28)
          height: toastLabel.implicitHeight + 16
          color: Vt.a(Vt.panel, 0.96)
          border.width: 1
          border.color: Vt.line
          z: 6
          Text {
            id: toastLabel
            anchors.centerIn: parent
            width: parent.width - 28
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "▓ " + root.toastText
            color: Vt.accent
            font.family: Vt.mono
            font.pixelSize: Vt.fsSmall
          }
        }

        InfoPanel {
          id: info
          anchors.fill: parent
          visible: false
          z: 10
          stateRef: store
          catalogRef: catalog
          onCloseRequested: info.visible = false
          onRebuildRequested: catalog.rebuild()
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        id: footer
        anchors.bottom: parent.bottom
        width: parent.width
        height: 28
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Vt.lineDim }
        Text {
          x: 16
          width: Math.max(0, footer.width - footerStatus.implicitWidth - 48)
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "[/]SEARCH  [R]RANDOM  [F]FAV  [G]GLOBE/FLAT  [M]STYLE  [S]SETTINGS  [HOME]RESET  [ESC]BACK"
          color: Vt.textDim
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
        }
        Text {
          id: footerStatus
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: catalog.cams.length + " CAMS  ·  " + catalog.sources.length + " SRC  ·  "
                + viewer.openCount() + " OPEN  ·  " + (catalog.building ? "BUILDING…  ·  " : "")
                + "RENDER " + globe.paintMs + "ms"
          color: Vt.textFaint
          font.family: Vt.mono
          font.pixelSize: Vt.fsCaption
        }
      }

      // window frame
      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: Vt.line
        z: 20
        enabled: false
      }
    }
  }
}
