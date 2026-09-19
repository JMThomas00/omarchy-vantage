.pragma library

// Camera search: case- and diacritic-insensitive, every token must match
// (AND). Ranking prefers name-prefix > name > place > anything else.

var COUNTRY = {
  US: "united states usa america", GB: "united kingdom uk england britain", FI: "finland",
  CA: "canada", AU: "australia", SG: "singapore", NO: "norway", JP: "japan", IT: "italy",
  KE: "kenya", ZA: "south africa", ZW: "zimbabwe", BW: "botswana", NA: "namibia",
  TZ: "tanzania", IS: "iceland", EC: "ecuador", ID: "indonesia", PH: "philippines",
  MX: "mexico", GL: "greenland", GT: "guatemala", HN: "honduras", IL: "israel",
  IE: "ireland", ES: "spain", DE: "germany", FR: "france", NZ: "new zealand"
}

var KIND_WORDS = { video: "live video stream", loop: "loop clip video", snapshot: "snapshot still image" }

function fold(s) {
  s = String(s || "").toLowerCase()
  try { s = s.normalize("NFD").replace(/[̀-ͯ]/g, "") } catch (e) {}
  return s
}

function hay(cam, srcLabel) {
  if (cam._h) return cam._h
  cam._n = fold(cam.name)
  cam._p = fold(cam.place)
  cam._h = cam._n + " | " + cam._p + " | " + fold(srcLabel || cam.src) + " | " + fold(cam.cat) + " | "
    + fold(COUNTRY[cam.country] || cam.country) + " | " + (KIND_WORDS[cam.kind] || "")
  return cam._h
}

function tokens(q) {
  var t = fold(q).split(/[\s,]+/)
  var out = []
  for (var i = 0; i < t.length; i++) if (t[i]) out.push(t[i])
  return out
}

/** Rank cams for query; returns up to `limit` cams, best first. */
function rank(cams, query, srcLabels, limit) {
  var toks = tokens(query)
  if (!toks.length) return []
  var hits = []
  for (var i = 0; i < cams.length; i++) {
    var c = cams[i], h = hay(c, srcLabels && srcLabels[c.src])
    var score = 0, ok = true
    for (var k = 0; k < toks.length; k++) {
      var t = toks[k]
      if (h.indexOf(t) < 0) { ok = false; break }
      if (c._n.indexOf(t) === 0) score += 6
      else if (c._n.indexOf(" " + t) >= 0) score += 4
      else if (c._n.indexOf(t) >= 0) score += 3
      else if (c._p.indexOf(t) >= 0) score += 2
      else score += 1
    }
    if (!ok) continue
    if (c.kind === "video") score += 0.5
    hits.push({ c: c, s: score })
  }
  hits.sort(function (a, b) { return b.s - a.s || (a.c.name < b.c.name ? -1 : 1) })
  var out = []
  for (var j = 0; j < hits.length && j < limit; j++) out.push(hits[j].c)
  return out
}
