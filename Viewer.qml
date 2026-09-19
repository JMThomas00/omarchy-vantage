import QtQuick
import Quickshell
import Quickshell.Io
import "Viewer.js" as ViewerJs

// Opens cameras in floating windows. Video/loop cameras open in mpv (Omarchy
// floats and centers mpv windows by default); snapshot cameras open in a
// SnapshotWindow. One fresh Process per spawn (a shared Process silently drops
// the second command when two are started in quick succession).
//
// Ad-free by construction: mpv is handed an agency stream URL directly, or a
// YouTube watch URL that yt-dlp resolves to the raw HLS manifest. No player
// page or embed is ever loaded, so there is no ad-insertion path.
Item {
  id: root

  property var stateRef: null
  property var srcLabels: ({})

  signal toast(string message)
  signal streamDead(string id)      // an agency stream answered a definitive HTTP 4xx

  property var connecting: ({})
  property var _procs: ({})       // id -> { proc, startedAt, cam }
  property var _snaps: ({})       // id -> SnapshotWindow
  property var _order: []         // ids, oldest first

  function isOpen(id) { return _procs[id] !== undefined || _snaps[id] !== undefined }
  function openCount() { return _order.length }

  function open(cam) {
    if (!cam) return
    if (root.isOpen(cam.id)) { root.toast("Already open: " + cam.name); return }
    while (root._order.length >= (root.stateRef ? root.stateRef.maxViewers : 4)) root._closeOldest()
    if (cam.kind === "snapshot") root._openSnapshot(cam)
    else root._openMpv(cam)
  }

  function _mark(id, on) {
    var c = Object.assign({}, root.connecting)
    if (on) c[id] = true
    else delete c[id]
    root.connecting = c
  }

  function _closeOldest() {
    var id = root._order[0]
    root._order = root._order.slice(1)
    if (root._procs[id]) { root._procs[id].closing = true; root._procs[id].proc.signal(15) }
    if (root._snaps[id]) root._snaps[id].visible = false
  }

  function _register(id) { root._order = root._order.concat([id]) }
  function _unregister(id) { root._order = root._order.filter(function (x) { return x !== id }) }

  // ---------------------------------------------------------------- mpv

  function _openMpv(cam, isRetry) {
    var accent = Vt.accent.toString()
    var argv = ViewerJs.mpvArgv(cam, {
      title: "vantage:" + cam.id, name: cam.name, place: cam.place,
      font: Vt.mono, accent: accent.length === 9 ? "#" + accent.slice(3) : accent,
      volume: root.stateRef ? root.stateRef.volume : 60
    })
    if (!argv) { root.toast("Blocked: unexpected stream address for " + cam.name); return }

    var proc = mpvComp.createObject(root, { camId: cam.id, command: argv })
    var map = Object.assign({}, root._procs)
    map[cam.id] = { proc: proc, startedAt: Date.now(), cam: cam, closing: false, retried: isRetry === true }
    root._procs = map
    root._register(cam.id)
    root._mark(cam.id, true)
    proc.running = true
    if (isRetry !== true) root.toast("Opening " + cam.name + " …")
    var id = cam.id
    Qt.callLater(function () { clearTimer.createObject(root, { camId: id }) })
  }

  function _onMpvExit(id, code, tail, proc) {
    var entry = root._procs[id]
    if (code !== 0 && code !== 4 && entry && !entry.closing)
      console.warn("[vantage] mpv exited code=" + code + " id=" + id + " tail=" + String(tail || "").replace(/\s+/g, " ").slice(-200))
    var m = Object.assign({}, root._procs)
    delete m[id]
    root._procs = m
    root._unregister(id)
    root._mark(id, false)
    // code 4 = mpv quit on a signal (someone closed/killed it), not a failure.
    if (entry && !entry.closing && code !== 0 && code !== 4 && Date.now() - entry.startedAt < 60000) {
      var hint = code === 127 ? "mpv could not be started (install it: omarchy pkg add mpv)"
        : (ViewerJs.isYoutube(entry.cam.stream)
           ? "yt-dlp could not resolve it (try: yt-dlp -U / pacman -Syu yt-dlp)"
           : "the stream did not respond")
      var last = String(tail || "").trim().split("\n").pop()
      // A definitive 4xx from an agency stream means it is gone, not flaky: remember that.
      if (code !== 127 && !ViewerJs.isYoutube(entry.cam.stream) && /HTTP error 4[0-9][0-9]/.test(String(tail)))
        root.streamDead(entry.cam.id)
      // YouTube live streams hiccup ("technical difficulties") far more often than
      // they stay down: retry once, quietly, before giving up.
      if (code !== 127 && ViewerJs.isYoutube(entry.cam.stream) && !entry.retried) {
        root.toast("Retrying " + entry.cam.name + " …")
        retryComp.createObject(root, { cam: entry.cam })
        proc.destroy()
        return
      }
      // A dead live feed is common for agency cams: fall back to its latest still.
      if (ViewerJs.urlAllowed(entry.cam.thumb)) {
        root.toast("Live stream unavailable for " + entry.cam.name + " (" + hint + "). Showing the latest snapshot.")
        Qt.callLater(function () { if (!root.isOpen(entry.cam.id)) root._openSnapshot(entry.cam) })
      } else {
        root.toast("Stream failed for " + entry.cam.name + ": " + hint + (last ? "  [" + last.slice(0, 90) + "]" : ""))
      }
    }
    proc.destroy()
  }

  Component {
    id: mpvComp
    Process {
      id: p
      property string camId: ""
      property string tail: ""
      property bool everStarted: false
      stderr: SplitParser { onRead: function (line) { p.tail = (p.tail + "\n" + line).slice(-600) } }
      stdout: SplitParser { onRead: function (line) { p.tail = (p.tail + "\n" + line).slice(-600) } }
      onStarted: p.everStarted = true
      onExited: function (code) { root._onMpvExit(camId, code, tail, p) }
      // If the binary cannot be started (mpv not installed) Quickshell emits neither started
      // nor exited: the process just stops "running". Without this the camera would stay marked
      // open forever ("Already open") and hold a viewer slot.
      onRunningChanged: if (!p.running && !p.everStarted) Qt.callLater(function () { root._onMpvExit(p.camId, 127, "could not start mpv", p) })
    }
  }

  Component {
    id: retryComp
    Timer {
      property var cam: null
      interval: 2500
      running: true
      onTriggered: { if (!root.isOpen(cam.id)) root._openMpv(cam, true); destroy() }
    }
  }

  Component {
    id: clearTimer
    Timer {
      property string camId: ""
      interval: 9000
      running: true
      onTriggered: { root._mark(camId, false); destroy() }
    }
  }

  // ---------------------------------------------------------------- snapshot windows

  function _openSnapshot(cam) {
    if (!ViewerJs.urlAllowed(cam.thumb)) { root.toast("Blocked: unexpected image address for " + cam.name); return }
    var w = snapComp.createObject(root, { cam: cam, srcLabel: root.srcLabels[cam.src] || cam.src,
                                          scanlines: root.stateRef ? root.stateRef.scanlines : false })
    var map = Object.assign({}, root._snaps)
    map[cam.id] = w
    root._snaps = map
    root._register(cam.id)
    w.visible = true
    var id = cam.id
    w.closeRequested.connect(function () {
      var m = Object.assign({}, root._snaps)
      delete m[id]
      root._snaps = m
      root._unregister(id)
      w.destroy()
    })
  }

  Component { id: snapComp; SnapshotWindow {} }

  Component.onDestruction: {
    for (var id in root._procs) { root._procs[id].closing = true; root._procs[id].proc.signal(15) }
  }
}
