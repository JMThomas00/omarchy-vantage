.pragma library

// URL safety + argv construction for the floating viewers. The catalog builder
// already drops records with unexpected hosts; this re-checks right before a
// URL is handed to mpv (defense in depth: a hand-edited catalog.json must not
// be able to make mpv open an arbitrary URL).

var ALLOWED_HOSTS = {
  "wzmedia.dot.ca.gov": true, "cwwp2.dot.ca.gov": true, "s3-eu-west-1.amazonaws.com": true,
  "weathercam.digitraffic.fi": true, "www.drivebc.ca": true,
  "webcams.transport.nsw.gov.au": true, "images.data.gov.sg": true,
  "www.youtube.com": true, "i.ytimg.com": true
}

var YT_WATCH = /^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{11}$/
// Strict authority parsing. The earlier "split on ':' and take the first piece" let
// https://allowed.host:x@evil.com/ through (userinfo before the real host), so the host
// must be plain letters/digits/dots, with no userinfo, and the port empty or 443.
function hostOf(url) {
  url = String(url || "")
  if (!/^[\x21-\x7e]+$/.test(url) || url.indexOf("\\") >= 0) return ""
  var m = /^https:\/\/([A-Za-z0-9.-]{1,253})(?::([0-9]{1,5}))?(?=[\/?#]|$)/.exec(url)
  if (!m) return ""
  if (m[2] && m[2] !== "443") return ""
  return m[1].toLowerCase()
}

function urlAllowed(url) {
  url = String(url || "")
  if (url.length > 500 || url.charAt(0) === "-") return false
  var host = hostOf(url)
  if (!ALLOWED_HOSTS[host]) return false
  if (host === "s3-eu-west-1.amazonaws.com" && url.indexOf("https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/") !== 0) return false
  if (host === "www.youtube.com" && !YT_WATCH.test(url)) return false
  return true
}


function isYoutube(url) { return YT_WATCH.test(String(url || "")) }

// mpv expands ${...} in --osd-playing-msg; "$" must be doubled to be literal.
function mpvEscape(s) { return String(s || "").replace(/\$/g, "$$$$").replace(/[\r\n]+/g, " ") }

/**
 * argv for a video/loop camera, or null if the URL is not allowed.
 * o: { title, name, place, font, accent, volume }
 */
function mpvArgv(cam, o) {
  if (!urlAllowed(cam.stream)) return null
  var yt = isYoutube(cam.stream)
  var hex = "#" + String(o.accent || "#ffffff").replace(/^#/, "").slice(0, 6)
  var argv = ["mpv", "--no-config", "--force-window=yes", "--keep-open=no",
    "--title=" + mpvEscape(o.title),
    "--autofit=960x540",
    "--osd-level=1", "--osd-font=" + (o.font || "monospace"), "--osd-font-size=28", "--osd-color=" + hex,
    "--osd-playing-msg=" + mpvEscape(o.name + (o.place ? "  ·  " + o.place : "")),
    "--osd-playing-msg-duration=4000",
    "--background-color=#000000", "--volume=" + (o.volume === undefined ? 60 : o.volume),
    "--cache=yes", "--demuxer-max-bytes=48MiB", "--network-timeout=20",
    "--ytdl=" + (yt ? "yes" : "no")]
  if (yt) argv.push("--ytdl-format=bv*[height<=720]+ba/b")
  // A playlist/manifest may only pull http(s) segments, never file:// or other protocols
  // (a compromised one could otherwise point mpv at local files). Verified against real
  // Caltrans HLS, TfL mp4 and live YouTube (bv+ba HLS, played 14 s with and without it).
  argv.push('--demuxer-lavf-o=protocol_whitelist="http,https,tls,tcp,crypto,data"')
  if (cam.kind === "loop") argv.push("--loop-file=inf")
  argv.push("--", cam.stream)
  return argv
}
