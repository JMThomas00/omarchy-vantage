.pragma library

// Projection, dot-layer drawing and clustering for Globe.qml. Pure functions,
// no QML objects, so they can be reasoned about (and profiled) on their own.
//
// World frame: unit vectors (x, y, z) = (cos(lat)cos(lon), cos(lat)sin(lon), sin(lat)).
// Globe view: rotate so the view centre lands on +x, then screen = (y, z).
//   sx = cx + R*y2      sy = cy - R*z2      visible when x2 > 0
// Flat view: equirectangular, sx = cx + (lon-lon0)*ppd, sy = cy - (lat-lat0)*ppd.

var DEG = Math.PI / 180
var RAD = 180 / Math.PI

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

function wrapLon(lon) {
  while (lon > 180) lon -= 360
  while (lon < -180) lon += 360
  return lon
}

/** Unit vectors for cams[idx].lat/lon -> Float32Array(3n). */
function unitVectors(cams) {
  var out = new Float32Array(cams.length * 3)
  for (var i = 0; i < cams.length; i++) {
    var la = cams[i].lat * DEG, lo = cams[i].lon * DEG
    var cl = Math.cos(la)
    out[i * 3] = cl * Math.cos(lo)
    out[i * 3 + 1] = cl * Math.sin(lo)
    out[i * 3 + 2] = Math.sin(la)
  }
  return out
}

/** Typed per-camera arrays used by the hot clustering loop. */
function prepCams(cams) {
  var n = cams.length, xyz = new Float32Array(n * 3), lat = new Float32Array(n)
  var lon = new Float32Array(n), kind = new Uint8Array(n)
  var rank = { video: 0, loop: 1, snapshot: 2 }
  for (var i = 0; i < n; i++) {
    var la = cams[i].lat * DEG, lo = cams[i].lon * DEG, cl = Math.cos(la)
    xyz[i * 3] = cl * Math.cos(lo)
    xyz[i * 3 + 1] = cl * Math.sin(lo)
    xyz[i * 3 + 2] = Math.sin(la)
    lat[i] = cams[i].lat
    lon[i] = cams[i].lon
    kind[i] = rank[cams[i].kind] === undefined ? 2 : rank[cams[i].kind]
  }
  return { n: n, xyz: xyz, lat: lat, lon: lon, kind: kind }
}

/** Land dots from the packed [lat10, lon10, ...] arrays -> {xyz, lat, lon, n}. */
function prepDots(packed) {
  var n = packed.length / 2
  var xyz = new Float32Array(n * 3), lat = new Float32Array(n), lon = new Float32Array(n)
  for (var i = 0; i < n; i++) {
    var la = packed[i * 2] / 10, lo = packed[i * 2 + 1] / 10
    lat[i] = la
    lon[i] = lo
    var cl = Math.cos(la * DEG)
    xyz[i * 3] = cl * Math.cos(lo * DEG)
    xyz[i * 3 + 1] = cl * Math.sin(lo * DEG)
    xyz[i * 3 + 2] = Math.sin(la * DEG)
  }
  return { xyz: xyz, lat: lat, lon: lon, n: n }
}

/** 3x3 view rotation as a flat array [m00..m22] (row-major) for centre (lat0, lon0) in degrees. */
function viewMatrix(lat0, lon0) {
  var p = lat0 * DEG, l = lon0 * DEG
  var cp = Math.cos(p), sp = Math.sin(p), cl = Math.cos(l), sl = Math.sin(l)
  return [cp * cl, cp * sl, sp,
          -sl, cl, 0,
          -sp * cl, -sp * sl, cp]
}

/** Globe: project one unit vector. Returns [sx, sy, depth]. */
function projectGlobe(m, x, y, z, cx, cy, R) {
  var x2 = m[0] * x + m[1] * y + m[2] * z
  var y2 = m[3] * x + m[4] * y
  var z2 = m[6] * x + m[7] * y + m[8] * z
  return [cx + R * y2, cy - R * z2, x2]
}

/** Any projection: lat/lon (deg) -> [sx, sy, visible(0/1), depth]. */
function projectLatLon(view, lat, lon) {
  if (view.proj === "flat") {
    var dl = wrapLon(lon - view.lon0)
    return [view.cx + dl * view.ppd, view.cy - (lat - view.lat0) * view.ppd, 1, 1]
  }
  var cl = Math.cos(lat * DEG)
  var p = projectGlobe(view.m, cl * Math.cos(lon * DEG), cl * Math.sin(lon * DEG), Math.sin(lat * DEG),
                       view.cx, view.cy, view.R)
  return [p[0], p[1], p[2] > 0.001 ? 1 : 0, p[2]]
}

/** Inverse: screen point -> [lat, lon] or null (off the globe). */
function screenToLatLon(view, sx, sy) {
  if (view.proj === "flat") {
    return [clamp(view.lat0 - (sy - view.cy) / view.ppd, -90, 90),
            clamp(view.lon0 + (sx - view.cx) / view.ppd, -180, 180)]
  }
  var y2 = (sx - view.cx) / view.R, z2 = -(sy - view.cy) / view.R
  var r2 = y2 * y2 + z2 * z2
  if (r2 > 1) return null
  var x2 = Math.sqrt(1 - r2), m = view.m
  var x = m[0] * x2 + m[3] * y2 + m[6] * z2
  var y = m[1] * x2 + m[4] * y2 + m[7] * z2
  var z = m[2] * x2 + m[5] * y2 + m[8] * z2
  return [Math.asin(clamp(z, -1, 1)) * RAD, Math.atan2(y, x) * RAD]
}

// ---------------------------------------------------------------- land dots

/**
 * Draw land dots as squares in three depth bands (limb dimmer) using one path
 * per band, so a frame costs a handful of fill() calls, not thousands.
 */
function drawLandGlobe(ctx, dots, view, size, colors) {
  var m = view.m, cx = view.cx, cy = view.cy, R = view.R, xyz = dots.xyz, n = dots.n
  var half = size / 2
  var bands = [[], [], []]
  for (var i = 0; i < n; i++) {
    var x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2]
    var x2 = m[0] * x + m[1] * y + m[2] * z
    if (x2 <= 0.02) continue
    var px = cx + R * (m[3] * x + m[4] * y)
    var py = cy - R * (m[6] * x + m[7] * y + m[8] * z)
    if (px < -6 || py < -6 || px > view.w + 6 || py > view.h + 6) continue
    bands[x2 > 0.55 ? 0 : (x2 > 0.22 ? 1 : 2)].push(px - half, py - half)
  }
  for (var b = 0; b < 3; b++) {
    var pts = bands[b]
    if (!pts.length) continue
    ctx.fillStyle = colors[b]
    for (var k = 0; k < pts.length; k += 2) ctx.fillRect(pts[k], pts[k + 1], size, size)
  }
}

function drawLandFlat(ctx, dots, view, size, color) {
  // One fillRect per dot, NOT one path holding every rect: Qt tessellates a big multi-rectangle path
  // on the CPU, which made the flat map ~4x slower to paint (measured: 7 -> 27 fps at world zoom).
  var half = size / 2, n = dots.n, lat = dots.lat, lon = dots.lon
  ctx.fillStyle = color
  var cx = view.cx, cy = view.cy, ppd = view.ppd, lat0 = view.lat0, lon0 = view.lon0, w = view.w, h = view.h
  for (var i = 0; i < n; i++) {
    var py = cy - (lat[i] - lat0) * ppd
    if (py < -6 || py > h + 6) continue
    var dl = lon[i] - lon0
    if (dl > 180) dl -= 360; else if (dl < -180) dl += 360
    var px = cx + dl * ppd
    if (px < -6 || px > w + 6) continue
    ctx.fillRect(px - half, py - half, size, size)
  }
}

// ---------------------------------------------------------------- graticule

function drawGraticule(ctx, view, color, stepDeg) {
  ctx.strokeStyle = color
  ctx.lineWidth = 1
  ctx.beginPath()
  var step = stepDeg || 30, i, j, p, prev
  if (view.proj === "flat") {
    // Every grid line on the flat map is a straight line: no need to project hundreds of points.
    var gx0 = view.cx + (-180 - view.lon0) * view.ppd, gx1 = view.cx + (180 - view.lon0) * view.ppd
    var gy0 = view.cy - (90 - view.lat0) * view.ppd, gy1 = view.cy + (90 + view.lat0) * view.ppd
    for (var glon = -180; glon < 180; glon += step) {
      var gx = view.cx + (glon - view.lon0) * view.ppd
      if (gx < -2 || gx > view.w + 2) continue
      ctx.moveTo(gx, Math.max(-2, gy0)); ctx.lineTo(gx, Math.min(view.h + 2, gy1))
    }
    for (var glat = -90 + step; glat < 90; glat += step) {
      var gy = view.cy - (glat - view.lat0) * view.ppd
      if (gy < -2 || gy > view.h + 2) continue
      ctx.moveTo(Math.max(-2, gx0), gy); ctx.lineTo(Math.min(view.w + 2, gx1), gy)
    }
    ctx.stroke()
    return
  }
  for (var lon = -180; lon < 180; lon += step) {          // meridians
    prev = null
    for (var lat = -90; lat <= 90; lat += 5) {
      p = projectLatLon(view, lat, lon)
      if (p[2] && prev) { ctx.moveTo(prev[0], prev[1]); ctx.lineTo(p[0], p[1]) }
      prev = p[2] ? p : null
    }
  }
  for (var la = -90 + step; la < 90; la += step) {         // parallels
    prev = null
    for (var lo = -180; lo <= 180; lo += 5) {
      p = projectLatLon(view, la, lo)
      if (view.proj === "flat" && prev && Math.abs(p[0] - prev[0]) > view.w / 2) prev = null
      if (p[2] && prev) { ctx.moveTo(prev[0], prev[1]); ctx.lineTo(p[0], p[1]) }
      prev = p[2] ? p : null
    }
  }
  ctx.stroke()
}

// ---------------------------------------------------------------- clustering

// ------------------------------------------------------------ cluster pyramid
//
// A per-frame loop over every camera is too slow in QML's JS engine at 6k+
// cameras, so clustering is precomputed: a pyramid of geographic cell levels
// (coarse -> fine), built once per catalog/filter change. Each frame then
// picks the level whose cells are ~cellPx wide on screen and projects only
// that level's clusters inside the visible latitude band.

var LEVEL_DEGS = [24, 12, 6, 3, 1.5, 0.75, 0.35, 0.15, 0.06, 0.02, 0.006]   // the last two only matter at the extra-deep zoom of the imagery styles

function buildPyramid(cd, idxList) {
  var levels = []
  var lat = cd.lat, lon = cd.lon, kind = cd.kind, xyz = cd.xyz
  for (var L = 0; L < LEVEL_DEGS.length; L++) {
    var deg = LEVEL_DEGS[L], cells = {}, list = []
    for (var q = 0; q < idxList.length; q++) {
      var i = idxList[q]
      var la = lat[i], lo = lon[i]
      var row = Math.floor((la + 90) / deg)
      var rowLat = -90 + (row + 0.5) * deg
      var lonDeg = deg / Math.max(0.2, Math.cos(rowLat * DEG))
      var key = row * 100003 + Math.floor((lo + 180) / lonDeg)
      var c = cells[key]
      if (c === undefined) {
        c = cells[key] = { n: 0, x: 0, y: 0, z: 0, rep: i, rk: 9, kinds: 0 }
        list.push(c)
      }
      c.n++
      c.x += xyz[i * 3]; c.y += xyz[i * 3 + 1]; c.z += xyz[i * 3 + 2]
      c.kinds |= (1 << kind[i])
      if (kind[i] < c.rk) { c.rk = kind[i]; c.rep = i }
    }
    list.sort(function (p, r) { return (p.z / p.n) - (r.z / r.n) })   // by ~sin(lat): ascending latitude
    var n = list.length
    var out = { deg: deg, n: n, lat: new Array(n), lon: new Array(n), vx: new Array(n), vy: new Array(n),
                vz: new Array(n), cnt: new Array(n), rep: new Array(n), kinds: new Array(n) }
    for (var k = 0; k < n; k++) {
      var e = list[k]
      var len = Math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) || 1
      out.vx[k] = e.x / len; out.vy[k] = e.y / len; out.vz[k] = e.z / len
      if (e.n === 1) { out.lat[k] = lat[e.rep]; out.lon[k] = lon[e.rep] }
      else { out.lat[k] = Math.asin(clamp(e.z / len, -1, 1)) * RAD; out.lon[k] = Math.atan2(e.y, e.x) * RAD }
      out.cnt[k] = e.n; out.rep[k] = e.rep; out.kinds[k] = e.kinds
    }
    levels.push(out)
  }
  return { levels: levels }
}

/** First index in ascending arr whose value >= v. */
function lowerBound(arr, v) {
  var lo = 0, hi = arr.length
  while (lo < hi) { var mid = (lo + hi) >> 1; if (arr[mid] < v) lo = mid + 1; else hi = mid }
  return lo
}

/** Visible clusters at the level matching cellPx: [{x, y, n, rep, lat, lon, kinds}]. */
function clusterView(pyr, view, cellPx) {
  var levels = pyr.levels
  var flat = view.proj === "flat"
  var pxPerDeg = flat ? view.ppd : view.R * DEG
  var target = cellPx / pxPerDeg
  var best = 0, bestD = Infinity
  for (var L = 0; L < levels.length; L++) {
    var d = Math.abs(Math.log(levels[L].deg / target))
    if (d < bestD) { bestD = d; best = L }
  }
  var lv = levels[best], n = lv.n
  var cx = view.cx, cy = view.cy, w = view.w, h = view.h, pad = 24
  // visible latitude band -> index range (arrays are sorted by ascending latitude)
  var span = Math.min(90, (Math.max(w, h) / 2 + pad + 30) / pxPerDeg)
  var i0 = 0, i1 = n
  if (span < 88) {
    var sinLo = Math.sin(clamp(view.lat0 - span, -90, 90) * DEG), sinHi = Math.sin(clamp(view.lat0 + span, -90, 90) * DEG)
    // vz is the normalised centroid's sin(lat); sorted ascending by (sum z / n), close enough to vz order.
    // Widen slightly so the sort-key/vz mismatch can never drop a visible cluster.
    var loBound = sinLo - 0.02, hiBound = sinHi + 0.02
    i0 = 0
    while (i0 < n && lv.vz[i0] < loBound) i0++
    i1 = i0
    while (i1 < n && lv.vz[i1] <= hiBound) i1++
  }
  var out = [], m = view.m, R = view.R, lat0 = view.lat0, lon0 = view.lon0, ppd = view.ppd
  for (var k = i0; k < i1; k++) {
    var px, py
    if (flat) {
      var dl = lv.lon[k] - lon0
      if (dl > 180) dl -= 360; else if (dl < -180) dl += 360
      px = cx + dl * ppd
      py = cy - (lv.lat[k] - lat0) * ppd
    } else {
      var x = lv.vx[k], y = lv.vy[k], z = lv.vz[k]
      if (m[0] * x + m[1] * y + m[2] * z <= 0.02) continue
      px = cx + R * (m[3] * x + m[4] * y)
      py = cy - R * (m[6] * x + m[7] * y + m[8] * z)
    }
    if (px < -pad || py < -pad || px > w + pad || py > h + pad) continue
    out.push({ x: px, y: py, n: lv.cnt[k], rep: lv.rep[k], lat: lv.lat[k], lon: lv.lon[k], kinds: lv.kinds[k], fav: false })
  }
  return out
}

/** Cluster whose marker contains (sx, sy) (nearest wins), or null. */
function hit(clusters, sx, sy, radius) {
  var best = null, bd = Infinity
  for (var i = 0; i < clusters.length; i++) {
    var c = clusters[i], dx = c.x - sx, dy = c.y - sy, d = dx * dx + dy * dy
    var r = c.n > 1 ? clusterRadius(c.n) + 2 : radius
    if (d <= r * r && d < bd) { best = c; bd = d }
  }
  return best
}

function clusterRadius(n) { return Math.min(19, 8 + 2.2 * Math.log(n) / Math.LN2) }

// ---------------------------------------------------------------- great circles

function latLonToVec(lat, lon) {
  var cl = Math.cos(lat * DEG)
  return [cl * Math.cos(lon * DEG), cl * Math.sin(lon * DEG), Math.sin(lat * DEG)]
}

/** Angular distance in radians between two lat/lon points. */
function angularDistance(lat1, lon1, lat2, lon2) {
  var a = latLonToVec(lat1, lon1), b = latLonToVec(lat2, lon2)
  return Math.acos(clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1))
}

/** n+1 points along the great circle a->b, as [x, y, z] unit vectors. */
function greatCircle(lat1, lon1, lat2, lon2, n) {
  var a = latLonToVec(lat1, lon1), b = latLonToVec(lat2, lon2)
  var dot = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1)
  var om = Math.acos(dot), so = Math.sin(om), out = []
  for (var i = 0; i <= n; i++) {
    var t = i / n, f1, f2
    if (so < 1e-6) { f1 = 1 - t; f2 = t } else { f1 = Math.sin((1 - t) * om) / so; f2 = Math.sin(t * om) / so }
    out.push([f1 * a[0] + f2 * b[0], f1 * a[1] + f2 * b[1], f1 * a[2] + f2 * b[2]])
  }
  return out
}

/** Project a unit vector with an optional radial lift (globe) -> [sx, sy, visible]. */
function projectVec(view, v, lift) {
  if (view.proj === "flat") {
    var lat = Math.asin(clamp(v[2], -1, 1)) * RAD, lon = Math.atan2(v[1], v[0]) * RAD
    var dl = wrapLon(lon - view.lon0)
    return [view.cx + dl * view.ppd, view.cy - (lat - view.lat0) * view.ppd - lift * 40, 1]
  }
  var m = view.m, s = 1 + lift * 0.22
  var x2 = m[0] * v[0] + m[1] * v[1] + m[2] * v[2]
  var y2 = m[3] * v[0] + m[4] * v[1]
  var z2 = m[6] * v[0] + m[7] * v[1] + m[8] * v[2]
  return [view.cx + view.R * s * y2, view.cy - view.R * s * z2, x2 > 0.0 ? 1 : 0]
}

// ------------------------------------------------------------ glyph map styles
//
// Braille / teletext blocks / ASCII density all share one engine: the land dots
// (already precomputed) are forward-projected into a grid of character cells,
// each cell accumulates which sub-positions were hit, and a lookup table turns
// that into a glyph. Rows are then drawn as ONE fillText per row, and blank
// rows are skipped.

var BRAILLE_BIT = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]   // [row][col] -> dot bit
var QUAD_BIT = [[1, 2], [4, 8]]
var QUAD_CH = [" ", "▘", "▝", "▀", "▖", "▌", "▞", "▛", "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█"]
var ASCII_RAMP = [" ", ".", ":", "-", "=", "+", "*", "#", "%", "@"]

/** The glyph used for "nothing here", so a row never mixes fonts (advance widths could differ). */
function blankGlyph(style) { return style === "braille" ? "⠀" : " " }
/** A representative glyph, for measuring the font's advance width. */
function sampleGlyph(style) { return style === "braille" ? "⣿" : (style === "blocks" ? "█" : "M") }

/**
 * dots: prepDots(...) result. Returns { runs: [{row, col, text}] } (non-blank stretches only)
 * covering the view in cellW x cellH cells. `spacing` is the dot pitch in px (used only
 * to scale the ASCII ramp).
 */
function glyphRows(style, dots, view, cellW, cellH, spacing) {
  var cols = Math.ceil(view.w / cellW) + 1, rows = Math.ceil(view.h / cellH) + 1
  var total = cols * rows, cells = new Array(total), dsum = null, i
  for (i = 0; i < total; i++) cells[i] = 0
  if (style === "ascii") { dsum = new Array(total); for (i = 0; i < total; i++) dsum[i] = 0 }
  var table = null, sw = 1, sh = 1
  if (style === "braille") { table = BRAILLE_BIT; sw = 2; sh = 4 }
  else if (style === "blocks") { table = QUAD_BIT; sw = 2; sh = 2 }

  var flat = view.proj === "flat", m = view.m, xyz = dots.xyz, lat = dots.lat, lon = dots.lon, n = dots.n
  var cx = view.cx, cy = view.cy, R = view.R, ppd = view.ppd, lat0 = view.lat0, lon0 = view.lon0
  var w = view.w, h = view.h
  var m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m6 = m[6], m7 = m[7], m8 = m[8]

  // Each dot stands for a spacing x spacing footprint. Mark every sub-cell whose
  // centre lies inside it (always at least the one containing the dot). At world
  // zoom the footprint is smaller than a sub-cell so this is one cell per dot,
  // exactly as before; zoomed in it fills the neighbourhood so land stays
  // connected instead of dissolving into isolated specks.
  var subW = cellW / sw, subH = cellH / sh, half = spacing / 2
  var subCols = cols * sw, subRows = rows * sh
  var binary = !table && spacing > cellW * 1.15

  for (i = 0; i < n; i++) {
    var px, py, wgt = 1
    if (flat) {
      py = cy - (lat[i] - lat0) * ppd
      if (py < -spacing || py >= h + spacing) continue
      var dl = lon[i] - lon0
      if (dl > 180) dl -= 360; else if (dl < -180) dl += 360
      px = cx + dl * ppd
    } else {
      var x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2]
      var x2 = m0 * x + m1 * y + m2 * z
      if (x2 <= 0.02) continue
      wgt = x2
      px = cx + R * (m3 * x + m4 * y)
      py = cy - R * (m6 * x + m7 * y + m8 * z)
    }
    if (px < -spacing || py < -spacing || px >= w + spacing || py >= h + spacing) continue
    if (table) {
      var si = Math.floor(px / subW), sj = Math.floor(py / subH)
      var i0 = Math.min(si, Math.ceil((px - half) / subW - 0.5)), i1 = Math.max(si, Math.floor((px + half) / subW - 0.5))
      var j0 = Math.min(sj, Math.ceil((py - half) / subH - 0.5)), j1 = Math.max(sj, Math.floor((py + half) / subH - 0.5))
      for (var jj = j0; jj <= j1; jj++) {
        if (jj < 0 || jj >= subRows) continue
        var rowBase = ((jj / sh) | 0) * cols, bitRow = table[jj % sh]
        for (var ii = i0; ii <= i1; ii++) {
          if (ii < 0 || ii >= subCols) continue
          cells[rowBase + ((ii / sw) | 0)] |= bitRow[ii % sw]
        }
      }
    } else {
      var cc = Math.floor(px / cellW), rr = Math.floor(py / cellH)
      var c0 = Math.min(cc, Math.ceil((px - half) / cellW - 0.5)), c1 = Math.max(cc, Math.floor((px + half) / cellW - 0.5))
      var r0 = Math.min(rr, Math.ceil((py - half) / cellH - 0.5)), r1 = Math.max(rr, Math.floor((py + half) / cellH - 0.5))
      for (var r2 = r0; r2 <= r1; r2++) {
        if (r2 < 0 || r2 >= rows) continue
        for (var c2 = c0; c2 <= c1; c2++) {
          if (c2 < 0 || c2 >= cols) continue
          cells[r2 * cols + c2] += 1
          dsum[r2 * cols + c2] += wgt
        }
      }
    }
  }

  var expected = Math.max(1, cellW * cellH / (spacing * spacing))
  var blank = blankGlyph(style), runs = []
  for (var r = 0; r < rows; r++) {
    // Emit only the non-blank stretches of each row (allowing short blank gaps inside a
    // stretch): the Canvas shapes every glyph it is given, and most of a globe view is ocean
    // or empty space, so drawing whole rows wasted most of the frame.
    var base = r * cols, start = -1, gap = 0, parts = []
    for (var c = 0; c < cols; c++) {
      var v = cells[base + c], g
      if (style === "braille") g = v ? String.fromCharCode(0x2800 + v) : blank
      else if (style === "blocks") g = QUAD_CH[v]
      else if (v) {
        // coverage (how much of the cell is land) x depth (limb shading), so
        // interior cells settle on one glyph instead of flickering #%@
        var cov = binary ? 0.8 : Math.min(1, v / (expected * 0.7)), depth = dsum[base + c] / v
        g = ASCII_RAMP[Math.min(9, Math.floor(cov * (0.2 + 0.8 * depth) * 9.99))]
      } else g = " "
      if (v) {
        if (start < 0) { start = c; parts = [] }
        gap = 0
      } else if (start >= 0) {
        gap++
        if (gap > 2) {                                  // stretch ended (drop the trailing blanks)
          runs.push({ row: r, col: start, text: parts.slice(0, parts.length - (gap - 1)).join("") })
          start = -1; gap = 0
          continue
        }
      }
      if (start >= 0) parts.push(g)
    }
    if (start >= 0) runs.push({ row: r, col: start, text: parts.slice(0, parts.length - gap).join("") })
  }
  return { runs: runs }
}

// ------------------------------------------------------------ vector style

/** Packed polylines [[lat10, lon10, ...], ...] -> lines with unit vectors and a bounding cap. */
function prepLines(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var p = list[i], n = p.length / 2
    var la = new Array(n), lo = new Array(n), xs = new Array(n), ys = new Array(n), zs = new Array(n)
    var sx = 0, sy = 0, sz = 0, minLat = 91, maxLat = -91
    for (var k = 0; k < n; k++) {
      var lat = p[k * 2] / 10, lon = p[k * 2 + 1] / 10, cl = Math.cos(lat * DEG)
      la[k] = lat; lo[k] = lon
      xs[k] = cl * Math.cos(lon * DEG); ys[k] = cl * Math.sin(lon * DEG); zs[k] = Math.sin(lat * DEG)
      sx += xs[k]; sy += ys[k]; sz += zs[k]
      if (lat < minLat) minLat = lat
      if (lat > maxLat) maxLat = lat
    }
    var len = Math.sqrt(sx * sx + sy * sy + sz * sz) || 1
    var ccx = sx / len, ccy = sy / len, ccz = sz / len, rad = 0
    for (var q = 0; q < n; q++) {
      var d = Math.acos(clamp(xs[q] * ccx + ys[q] * ccy + zs[q] * ccz, -1, 1))
      if (d > rad) rad = d
    }
    out.push({ n: n, lat: la, lon: lo, x: xs, y: ys, z: zs, cx: ccx, cy: ccy, cz: ccz, rad: rad, minLat: minLat, maxLat: maxLat })
  }
  return out
}

/**
 * Add every visible polyline to the current canvas path (caller strokes it, so
 * a glow pass and a crisp pass can share one path build). Lines wholly outside
 * the view are skipped by their bounding cap; pen lifts at the horizon and at
 * the antimeridian.
 */
function tracePolylines(ctx, lines, view) {
  var flat = view.proj === "flat", m = view.m
  var cx = view.cx, cy = view.cy, R = view.R, ppd = view.ppd, lat0 = view.lat0, lon0 = view.lon0
  var w = view.w, h = view.h
  var m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m6 = m[6], m7 = m[7], m8 = m[8]
  var vc = latLonToVec(lat0, lon0)
  var half = flat ? 0 : Math.min(Math.PI / 2, Math.asin(Math.min(1, Math.sqrt(w * w + h * h) / 2 / R)))
  var latSpan = flat ? (h / 2 + 30) / ppd : 0
  ctx.beginPath()
  for (var i = 0; i < lines.length; i++) {
    var L = lines[i]
    if (flat) {
      if (L.maxLat < lat0 - latSpan || L.minLat > lat0 + latSpan) continue
    } else {
      var d = Math.acos(clamp(L.cx * vc[0] + L.cy * vc[1] + L.cz * vc[2], -1, 1))
      if (d > L.rad + Math.max(half, 0.05) + 0.05 && d > L.rad + Math.PI / 2) continue
      if (d - L.rad > Math.PI / 2) continue                    // whole line is behind the globe
    }
    var pen = false, prevX = 0
    var xs = L.x, ys = L.y, zs = L.z, la = L.lat, lo = L.lon, n = L.n
    for (var k = 0; k < n; k++) {
      var px, py
      if (flat) {
        var dl = lo[k] - lon0
        if (dl > 180) dl -= 360; else if (dl < -180) dl += 360
        px = cx + dl * ppd
        py = cy - (la[k] - lat0) * ppd
        if (pen && Math.abs(px - prevX) > w * 0.5) pen = false
      } else {
        var x = xs[k], y = ys[k], z = zs[k]
        if (m0 * x + m1 * y + m2 * z < 0.001) { pen = false; continue }
        px = cx + R * (m3 * x + m4 * y)
        py = cy - R * (m6 * x + m7 * y + m8 * z)
      }
      if (pen) ctx.lineTo(px, py)
      else { ctx.moveTo(px, py); pen = true }
      prevX = px
    }
  }
}

// ------------------------------------------------------------ plotter style

/** Land as small '+' marks (pen-plotter look): one path per depth band, one stroke each. */
function drawLandPlus(ctx, dots, view, half, colors, lineWidth) {
  var flat = view.proj === "flat", m = view.m, xyz = dots.xyz, lat = dots.lat, lon = dots.lon, n = dots.n
  var cx = view.cx, cy = view.cy, R = view.R, ppd = view.ppd, lat0 = view.lat0, lon0 = view.lon0
  var w = view.w, h = view.h
  var m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m6 = m[6], m7 = m[7], m8 = m[8]
  var bands = [[], [], []]
  for (var i = 0; i < n; i++) {
    var px, py, band = 0
    if (flat) {
      py = cy - (lat[i] - lat0) * ppd
      if (py < -6 || py > h + 6) continue
      var dl = lon[i] - lon0
      if (dl > 180) dl -= 360; else if (dl < -180) dl += 360
      px = cx + dl * ppd
    } else {
      var x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2]
      var x2 = m0 * x + m1 * y + m2 * z
      if (x2 <= 0.02) continue
      px = cx + R * (m3 * x + m4 * y)
      py = cy - R * (m6 * x + m7 * y + m8 * z)
      band = x2 > 0.55 ? 0 : (x2 > 0.22 ? 1 : 2)
    }
    if (px < -6 || px > w + 6 || py < -6 || py > h + 6) continue
    bands[band].push(px, py)
  }
  // Each '+' is two thin rects (fillRect batches; one path of thousands of line segments does not).
  var lw = lineWidth || 1, hl = lw / 2
  for (var b = 0; b < 3; b++) {
    var pts = bands[b]
    if (!pts.length) continue
    ctx.fillStyle = colors[b]
    for (var k = 0; k < pts.length; k += 2) {
      var qx = Math.round(pts[k]), qy = Math.round(pts[k + 1])
      ctx.fillRect(qx - half, qy - hl, 2 * half, lw)
      ctx.fillRect(qx - hl, qy - half, lw, 2 * half)
    }
  }
}

/** Compass-style tick marks: around the globe's limb, or along the flat map's frame. */
function drawTicks(ctx, view, color) {
  ctx.strokeStyle = color
  ctx.lineWidth = 1
  ctx.beginPath()
  var i
  if (view.proj === "flat") {
    var x0 = view.cx + (-180 - view.lon0) * view.ppd, x1 = view.cx + (180 - view.lon0) * view.ppd
    var y0 = view.cy - (90 - view.lat0) * view.ppd, y1 = view.cy + (90 + view.lat0) * view.ppd
    for (i = 0; i <= 36; i++) {                       // every 10 degrees of longitude, top and bottom
      var tx = x0 + i * 10 * view.ppd, tl = i % 3 === 0 ? 9 : 5
      ctx.moveTo(tx, y0); ctx.lineTo(tx, y0 - tl)
      ctx.moveTo(tx, y1); ctx.lineTo(tx, y1 + tl)
    }
    for (i = 0; i <= 18; i++) {                       // every 10 degrees of latitude, left and right
      var ty = y0 + i * 10 * view.ppd, tl2 = i % 3 === 0 ? 9 : 5
      ctx.moveTo(x0, ty); ctx.lineTo(x0 - tl2, ty)
      ctx.moveTo(x1, ty); ctx.lineTo(x1 + tl2, ty)
    }
  } else {
    for (i = 0; i < 72; i++) {                        // every 5 degrees around the limb
      var a = i * Math.PI / 36, len = i % 6 === 0 ? 11 : 5
      var c = Math.cos(a), s = Math.sin(a)
      ctx.moveTo(view.cx + c * view.R, view.cy + s * view.R)
      ctx.lineTo(view.cx + c * (view.R + len), view.cy + s * (view.R + len))
    }
  }
  ctx.stroke()
}

// ------------------------------------------------------------ day / night

/** Sub-solar point for a Date: { lat, lon } in degrees (low-precision almanac, ~0.5 deg). */
function sunPosition(date) {
  var d = date.getTime() / 86400000 + 2440587.5 - 2451545.0            // days since J2000
  var g = (357.529 + 0.98560028 * d) * DEG                              // mean anomaly
  var q = 280.459 + 0.98564736 * d                                      // mean longitude
  var L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * DEG     // ecliptic longitude
  var eps = (23.439 - 0.00000036 * d) * DEG
  var ra = Math.atan2(Math.cos(eps) * Math.sin(L), Math.cos(L))
  var dec = Math.asin(Math.sin(eps) * Math.sin(L))
  var gmst = (((280.46061837 + 360.98564736629 * d) % 360) + 360) % 360
  return { lat: dec * RAD, lon: wrapLon(ra * RAD - gmst) }
}

function _cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
function _norm(a) { var l = Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) || 1; return [a[0] / l, a[1] / l, a[2] / l] }

/**
 * Add the night-side region (sun elevation below `elev` radians) of the visible
 * globe to the current path; the caller fills it. The boundary is a small circle
 * around the sub-solar point: its visible arc is joined to the limb through the
 * night side, so the polygon is exactly (disc AND night).
 */
function nightPathGlobe(ctx, view, sun, elev) {
  var m = view.m, cx = view.cx, cy = view.cy, R = view.R
  var se = Math.sin(elev), ce = Math.cos(elev), N = 180, i
  var a = _norm(_cross(sun, Math.abs(sun[2]) > 0.95 ? [1, 0, 0] : [0, 0, 1])), b = _cross(sun, a)
  var sx = new Array(N), sy = new Array(N), vis = new Array(N), nVis = 0
  for (i = 0; i < N; i++) {
    var phi = i * 2 * Math.PI / N, cp = Math.cos(phi) * ce, sp = Math.sin(phi) * ce
    var x = sun[0] * se + a[0] * cp + b[0] * sp, y = sun[1] * se + a[1] * cp + b[1] * sp, z = sun[2] * se + a[2] * cp + b[2] * sp
    vis[i] = (m[0] * x + m[1] * y + m[2] * z) > 0
    sx[i] = cx + R * (m[3] * x + m[4] * y)
    sy[i] = cy - R * (m[6] * x + m[7] * y + m[8] * z)
    if (vis[i]) nVis++
  }
  var axis = m[0] * sun[0] + m[1] * sun[1] + m[2] * sun[2]      // sun's depth along the view axis
  if (nVis === 0) {                                             // circle entirely behind: disc is all night or all day
    if (axis < se) { ctx.moveTo(cx + R, cy); ctx.arc(cx, cy, R, 0, 2 * Math.PI) }
    return
  }
  if (nVis === N) {                                             // circle entirely in front: night is its interior
    ctx.moveTo(sx[0], sy[0])
    for (i = 1; i < N; i++) ctx.lineTo(sx[i], sy[i])
    ctx.closePath()
    return
  }
  // contiguous visible run (rotate so it starts right after an invisible point)
  var start = 0
  for (i = 0; i < N; i++) if (vis[i] && !vis[(i + N - 1) % N]) { start = i; break }
  var run = []
  for (i = 0; i < N && vis[(start + i) % N]; i++) run.push((start + i) % N)
  function snap(k) {                                            // put a run end exactly on the limb
    var dx = sx[k] - cx, dy = sy[k] - cy, l = Math.sqrt(dx * dx + dy * dy) || 1
    return [cx + dx / l * R, cy + dy / l * R, Math.atan2(dy, dx)]
  }
  var A = snap(run[0]), B = snap(run[run.length - 1])
  function limbIsNight(theta) {                                 // limb point at screen angle theta
    var v1 = Math.cos(theta), v2 = -Math.sin(theta)
    var wx = m[3] * v1 + m[6] * v2, wy = m[4] * v1 + m[7] * v2, wz = m[5] * v1 + m[8] * v2
    return wx * sun[0] + wy * sun[1] + wz * sun[2] < se
  }
  var TAU = 2 * Math.PI
  var delta = (((A[2] - B[2]) % TAU) + TAU) % TAU              // going from B increasing-angle to A
  var dir = limbIsNight(B[2] + delta / 2) ? 1 : -1
  var span = dir === 1 ? delta : TAU - delta
  ctx.moveTo(A[0], A[1])
  for (i = 1; i < run.length - 1; i++) ctx.lineTo(sx[run[i]], sy[run[i]])
  ctx.lineTo(B[0], B[1])
  var steps = Math.max(2, Math.ceil(span / (3 * DEG)))
  for (i = 1; i <= steps; i++) {
    var th = B[2] + dir * span * i / steps
    ctx.lineTo(cx + R * Math.cos(th), cy + R * Math.sin(th))
  }
  ctx.closePath()
}

/** Flat map: add night-side column rects (sun elevation below `elev` radians) to the path. */
/**
 * Day/night shading on the flat map for one sun elevation: the region where the sun is below `elev`,
 * filled with the current fillStyle as a handful of polygons (not hundreds of tall thin rectangles:
 * measured, those cost ~0.4 ms EACH to paint, which crawled at 3 fps; one polygon path per layer is cheap).
 *
 * Per 6 px column the night region is one or two latitude intervals; a run of columns with the same
 * interval count becomes one polygon whose edges are the boundary latitudes at each column centre
 * (a piecewise-linear terminator, no stair-steps), closed off at the first and last column edge. Only
 * columns that are on screen and inside the world are computed.
 */
function drawNightFlat(ctx, view, sunLat, sunLon, elev) {
  var sd = Math.sin(sunLat * DEG), cd = Math.cos(sunLat * DEG), se = Math.sin(elev)
  var ppd = view.ppd, STEP = 6, h = view.h
  var worldL = Math.round(view.cx + (-180 - view.lon0) * ppd), worldR = Math.round(view.cx + (180 - view.lon0) * ppd)
  var first = Math.max(0, worldL), last = Math.min(Math.ceil(view.w), worldR)
  var yOf = function (lat) { return Math.max(-2, Math.min(h + 2, view.cy - (lat - view.lat0) * ppd)) }
  var runs = [], open = [], prevCount = -1

  function flush() {
    for (var k = 0; k < open.length; k++) {
      var r = open[k]
      if (!r) continue
      r.xs.push(r.ex); r.lo.push(r.elo); r.hi.push(r.ehi)                          // end flush with the last column's right edge
      runs.push(r)
    }
    open = []
  }

  for (var px = first; px < last; px += STEP) {
    var wpx = Math.min(STEP, last - px)
    var lon = view.lon0 + (px + wpx / 2 - view.cx) / ppd
    var cosH = Math.cos((lon - sunLon) * DEG)
    var A = sd, B = cd * cosH, Rr = Math.sqrt(A * A + B * B)
    var b0 = -Math.PI / 2, b1 = Math.PI / 2, b2 = NaN, b3 = NaN     // sorted latitude bounds, no allocation
    if (Rr > Math.abs(se)) {
      var sn = Math.asin(se / Rr), psi = Math.atan2(B, A)
      var f1 = sn - psi, f2 = Math.PI - sn - psi
      while (f1 > Math.PI) f1 -= 2 * Math.PI
      while (f1 < -Math.PI) f1 += 2 * Math.PI
      while (f2 > Math.PI) f2 -= 2 * Math.PI
      while (f2 < -Math.PI) f2 += 2 * Math.PI
      var in1 = f1 > -Math.PI / 2 && f1 < Math.PI / 2, in2 = f2 > -Math.PI / 2 && f2 < Math.PI / 2
      if (in1 && in2) { b1 = Math.min(f1, f2); b2 = Math.max(f1, f2); b3 = Math.PI / 2 }
      else if (in1) { b1 = f1; b2 = Math.PI / 2 }
      else if (in2) { b1 = f2; b2 = Math.PI / 2 }
    }
    // intervals between the sorted bounds; night where the sun is below elev (tested at each midpoint)
    var bounds = [b0, b1]
    if (b2 === b2) bounds.push(b2)
    if (b3 === b3) bounds.push(b3)
    var ints = []
    for (var k = 0; k + 1 < bounds.length; k++) {
      var mid = (bounds[k] + bounds[k + 1]) / 2
      if (Math.sin(mid) * sd + Math.cos(mid) * cd * cosH < se) {
        if (ints.length && ints[ints.length - 1][1] === bounds[k]) ints[ints.length - 1][1] = bounds[k + 1]   // merge neighbours
        else ints.push([bounds[k], bounds[k + 1]])
      }
    }
    if (ints.length !== prevCount) { flush(); prevCount = ints.length }
    for (var q = 0; q < ints.length; q++) {
      var run = open[q], ylo = yOf(ints[q][0] * RAD), yhi = yOf(ints[q][1] * RAD)
      if (!run) {
        run = open[q] = { xs: [px], lo: [ylo], hi: [yhi], ex: 0, elo: 0, ehi: 0 }     // start flush with the column's left edge
      }
      run.xs.push(px + wpx / 2); run.lo.push(ylo); run.hi.push(yhi)
      run.ex = px + wpx; run.elo = ylo; run.ehi = yhi                              // remembered for the closing edge
    }
  }
  flush()

  ctx.beginPath()
  for (var r = 0; r < runs.length; r++) {
    var R = runs[r], n = R.xs.length
    ctx.moveTo(R.xs[0], R.lo[0])
    for (var i = 1; i < n; i++) ctx.lineTo(R.xs[i], R.lo[i])          // lower latitude edge, left to right
    for (var j = n - 1; j >= 0; j--) ctx.lineTo(R.xs[j], R.hi[j])     // upper latitude edge, back
    ctx.closePath()
  }
  ctx.fill()
}


// ------------------------------------------------------------ detail tiles (web-mercator XYZ)
//
// The satellite / topo / contour styles draw a whole-planet texture and, when zoomed in,
// stream web-mercator tiles for the visible area over it (see DetailLayer.qml).

/** Normalised web-mercator y (0 = north edge, 1 = south edge) of a latitude in degrees. */
function mercY(lat) {
  var la = clamp(lat, -85.05, 85.05) * DEG
  return 0.5 - Math.log(Math.tan(Math.PI / 4 + la / 2)) / (2 * Math.PI)
}

/** Web-mercator tile column / row of a coordinate at zoom z (column not wrapped). */
function tileX(lon, z) { return Math.floor((lon + 180) / 360 * Math.pow(2, z)) }
function tileY(lat, z) { return Math.floor(mercY(lat) * Math.pow(2, z)) }

/**
 * Bounds of what the window shows, relative to the view centre: { dLonMin, dLonMax, latMin, latMax }
 * in degrees, or null when nothing (or too much: > 200 degrees of longitude) is visible.
 */
function viewBounds(view) {
  var dMin = 1e9, dMax = -1e9, laMin = 90, laMax = -90, n = 0
  for (var i = 0; i <= 8; i++) {
    for (var j = 0; j <= 8; j++) {
      var ll = screenToLatLon(view, view.w * i / 8, view.h * j / 8)
      if (!ll) continue
      var d = wrapLon(ll[1] - view.lon0)
      if (d < dMin) dMin = d
      if (d > dMax) dMax = d
      if (ll[0] < laMin) laMin = ll[0]
      if (ll[0] > laMax) laMax = ll[0]
      n++
    }
  }
  if (!n || dMax - dMin > 200) return null
  return { dLonMin: dMin, dLonMax: dMax, latMin: laMin, latMax: laMax }
}

/** Tile range covering the bounds (expanded by `pad`, a fraction of the span) at zoom z. */
function tileRange(view, b, z, pad) {
  var dl = (b.dLonMax - b.dLonMin) * pad, dla = (b.latMax - b.latMin) * pad
  var x0 = tileX(view.lon0 + b.dLonMin - dl, z), x1 = tileX(view.lon0 + b.dLonMax + dl, z)
  var y0 = tileY(Math.min(84.9, b.latMax + dla), z), y1 = tileY(Math.max(-84.9, b.latMin - dla), z)
  return { x0: x0, y0: y0, cols: x1 - x0 + 1, rows: y1 - y0 + 1 }
}

/**
 * Choose the tile zoom and range for the current view, or null when the whole-planet
 * texture is already as sharp as it gets (zoomed out) or the view is unusable.
 *   maxZ      finest zoom the source has
 *   minZ      coarsest zoom worth fetching (below that the global texture is as good)
 *   maxTiles  most tiles per side (the patch texture is maxTiles*256 px square)
 *   bias      subtracted from the ideal zoom: 0 = one tile texel per screen pixel, 0.5 = up to ~1.4 texels
 *             per pixel (fewer, coarser tiles; loads faster and looks the same for smooth data)
 */
function detailPlan(view, maxZ, minZ, maxTiles, bias) {
  var b = viewBounds(view)
  if (!b) return null
  var pxPerDeg = view.proj === "flat" ? view.ppd : view.R * DEG
  var z = Math.min(maxZ, Math.ceil(Math.log(pxPerDeg * 360 / 256) / Math.LN2 - (bias || 0)))
  var r = null
  for (; z >= minZ; z--) {
    r = tileRange(view, b, z, 0.1)
    if (r.cols <= maxTiles && r.rows <= maxTiles) break
    r = null
  }
  if (!r) return null
  var n = Math.pow(2, z)
  r.y0 = Math.max(0, r.y0)
  r.rows = Math.min(r.rows, n - r.y0)
  r.cols = Math.min(r.cols, n)
  r.z = z
  r.bounds = tileRange(view, b, z, 0)          // unpadded, for the "still covered?" check
  return r
}
