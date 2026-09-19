#!/usr/bin/python3
"""Vantage catalog builder.

Fetches every enabled webcam source, normalizes each camera into one record
shape, and writes a single catalog.json atomically. Stdlib only.

Progress is printed to stdout as one JSON object per line so the QML side can
render a boot-log style readout while the build runs:

    {"ev":"source","src":"caltrans","status":"ok","count":3612}
    {"ev":"source","src":"tfl","status":"fail","error":"timeout"}
    {"ev":"done","total":7412,"path":"/home/.../catalog.json"}

Design rules:
  * Every adapter runs in isolation. One failing never blanks the catalog.
  * A failed adapter's cameras are carried over from the previous catalog
    (status "stale") so a flaky endpoint doesn't make pins vanish.
  * Only official, publisher-intended feeds. No embed pages, no players.
  * Every URL must be https and on an allowlisted host (see ALLOWED_HOSTS);
    anything else is dropped. The QML side re-checks before spawning mpv.
"""

import argparse
import concurrent.futures
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

UA = "omarchy-vantage/0.1"
MAX_BYTES = 40_000_000

# Hosts a record's streamUrl/thumbUrl may point at. Keep in sync with Viewer.js.
ALLOWED_HOSTS = {
    "wzmedia.dot.ca.gov",
    "cwwp2.dot.ca.gov",
    "s3-eu-west-1.amazonaws.com",   # TfL JamCam bucket (path checked below)
    "weathercam.digitraffic.fi",
    "www.drivebc.ca",
    "webcams.transport.nsw.gov.au",
    "images.data.gov.sg",
    "www.youtube.com",
    "i.ytimg.com",
}

YT_WATCH_RE = re.compile(r"^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$")
CALTRANS_DISTRICTS = {
    1: "Eureka", 2: "Redding", 3: "Marysville", 4: "Bay Area", 5: "San Luis Obispo",
    6: "Fresno", 7: "Los Angeles", 8: "San Bernardino", 9: "Bishop", 10: "Stockton",
    11: "San Diego", 12: "Orange County",
}


def emit(**obj):
    print(json.dumps(obj, separators=(",", ":")), flush=True)


# --------------------------------------------------------------------- http

def http_json(url, headers=None, timeout=25, retries=1):
    """GET + parse JSON. One retry, after a short pause, for transient network errors
    (timeouts, connection resets, 5xx); a 4xx is final."""
    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers={
            "User-Agent": UA, "Accept": "application/json", "Accept-Encoding": "gzip",
            **(headers or {}),
        })
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    raise ValueError("response too large")
                if r.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read(MAX_BYTES + 1)
                    if len(raw) > MAX_BYTES:
                        raise ValueError("decompressed response too large")
            return json.loads(raw)
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code < 500:
                raise
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            last = exc
        if attempt < retries:
            time.sleep(1.5)
    raise last


# ------------------------------------------------------------------- records

_AUTH_RE = re.compile(r"^https://([A-Za-z0-9.-]{1,253})(?::([0-9]{1,5}))?(?=[/?#]|$)")


def url_host(u):
    """Host of a plain https URL, or None. Strict on purpose: no userinfo ('@'), no
    backslashes, no spaces/control characters, port empty or 443 -- so the allowlist
    below cannot be fooled by https://allowed.host:x@evil.com/."""
    if not isinstance(u, str) or len(u) > 500 or not re.fullmatch(r"[\x21-\x7e]+", u) or "\\" in u:
        return None
    m = _AUTH_RE.match(u)
    if not m or (m.group(2) and m.group(2) != "443"):
        return None
    return m.group(1).lower()


def url_ok(u):
    host = url_host(u)
    if host is None or host not in ALLOWED_HOSTS:
        return False
    if host == "s3-eu-west-1.amazonaws.com" and not u.startswith(
            "https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/"):
        return False
    if host == "www.youtube.com" and not YT_WATCH_RE.match(u):
        return False
    return True


_CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]")


def clean(s, limit=120):
    """Display text from a remote source: control and bidi-override characters removed,
    whitespace collapsed, length bounded."""
    s = _CONTROL_RE.sub(" ", str(s or ""))
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def fnum(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f == f and abs(f) != float("inf") else None


def make(src, sid, name, lat, lon, kind, stream, thumb, place="", country="",
         category="traffic", refresh=60):
    lat, lon = fnum(lat), fnum(lon)
    if lat is None or lon is None:
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
        return None
    name = clean(name)
    if not name or not url_ok(thumb):
        return None
    if kind in ("video", "loop") and not url_ok(stream):
        return None
    if kind == "snapshot":
        stream = thumb
    sid = re.sub(r"[^A-Za-z0-9_.:-]", "_", str(sid))[:80]      # ids end up in window titles and argv
    return {
        "id": f"{src}:{sid}", "name": name, "place": clean(place), "country": country,
        "lat": round(lat, 5), "lon": round(lon, 5), "kind": kind, "src": src,
        "cat": category, "stream": stream, "thumb": thumb, "refresh": refresh,
    }


# ------------------------------------------------------------------ adapters

PROBE_BUDGET_SECONDS = 35        # most a single build may spend probing playlists
PROBE_DEAD_TTL = 3 * 86400       # a dead stream stays dead for days: don't re-ask
PROBE_ALIVE_TTL = 1 * 86400      # a live one is re-checked about daily


def _load_probe_cache(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def verify_playlists(cams, cache_path, workers=24, timeout=5):
    """Demote 'video' cameras whose HLS playlist is definitively dead to 'snapshot'.

    About a third of Caltrans' advertised live streams answer 404 (measured 734 of 2,183), and a
    LIVE pin that never plays is worse than an honest snapshot pin. Design constraints:

      * Only a definitive answer demotes: an HTTP error status, or a 200 that is not a playlist.
        Timeouts and network errors are inconclusive and keep the camera as video, so a blip
        never hides a working stream.
      * Polite and bounded: results are cached (dead for 3 days, alive for 1), and one build
        spends at most PROBE_BUDGET_SECONDS probing, newest-unknown first. Coverage therefore
        converges over successive builds instead of hammering the server (and stalling the
        refresh) with ~2,200 requests every time.

    Returns (demoted_count, probed_this_run, still_unchecked).
    """
    now = time.time()
    cache = _load_probe_cache(cache_path)
    targets = [c for c in cams if c["kind"] == "video"]
    ids = {c["id"] for c in targets}
    cache = {k: v for k, v in cache.items() if k in ids and isinstance(v, list) and len(v) == 2}

    todo = []
    for c in targets:
        entry = cache.get(c["id"])
        if entry and now - entry[0] < (PROBE_ALIVE_TTL if entry[1] else PROBE_DEAD_TTL):
            continue
        todo.append(c)
    todo.sort(key=lambda c: cache.get(c["id"], [0])[0])          # never-probed first, then oldest

    deadline = now + PROBE_BUDGET_SECONDS

    def probe(c):
        if time.time() > deadline:
            return c, None                                       # out of budget: leave for next build
        req = urllib.request.Request(c["stream"], headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return c, r.read(64).lstrip().startswith(b"#EXTM3U")
        except urllib.error.HTTPError:
            return c, False
        except Exception:
            return c, None                                       # timeout / network: inconclusive

    probed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for c, alive in pool.map(probe, todo):
            if alive is not None:
                cache[c["id"]] = [now, bool(alive)]
                probed += 1

    demoted = 0
    for c in targets:
        entry = cache.get(c["id"])
        if entry and not entry[1]:
            c["kind"] = "snapshot"
            c["stream"] = c["thumb"]
            demoted += 1
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        tmp = cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cache, fh, separators=(",", ":"))
        os.replace(tmp, cache_path)
    except OSError:
        pass
    return demoted, probed, len([c for c in targets if c["id"] not in cache])


PREV = {}          # source id -> cameras from the previous catalog (set by main), used to keep data through outages


def fetch_caltrans(cache_path=None):
    out = []

    def one(d):
        url = f"https://cwwp2.dot.ca.gov/data/d{d}/cctv/cctvStatusD{d:02d}.json"
        try:
            return d, http_json(url, timeout=40), None
        except Exception as exc:                 # one slow district must not sink the whole source
            return d, None, f"{type(exc).__name__}"

    failed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for d, doc, err in pool.map(one, CALTRANS_DISTRICTS):
            if doc is None:
                failed.append(f"D{d}")
                continue
            for row in doc.get("data", []):
                c = row.get("cctv") or {}
                if str(c.get("inService")).lower() != "true":
                    continue
                loc, img = c.get("location") or {}, c.get("imageData") or {}
                hls = img.get("streamingVideoURL") or ""
                still = (img.get("static") or {}).get("currentImageURL") or ""
                near = clean(loc.get("nearbyPlace"))
                place = ", ".join(x for x in (near, CALTRANS_DISTRICTS[d] + " area, CA") if x)
                rec = make("caltrans", f"D{d}-{c.get('index')}", loc.get("locationName"),
                           loc.get("latitude"), loc.get("longitude"),
                           "video" if hls else "snapshot", hls, still,
                           place=place, country="US",
                           refresh=int(fnum((img.get("static") or {}).get("currentImageUpdateFrequency")) or 2) * 60)
                if rec:
                    out.append(rec)
    # A district that did not answer keeps its previous cameras rather than vanishing: an outage of a
    # few of the twelve district servers must not delete thousands of cameras from the catalog.
    if len(failed) == len(CALTRANS_DISTRICTS):
        raise RuntimeError("no Caltrans district answered")            # main() keeps the previous cameras and marks them stale
    kept = 0
    for dname in failed:
        old = [c for c in PREV.get("caltrans", []) if str(c.get("id", "")).startswith(f"caltrans:{dname}-")]
        out.extend(old)
        kept += len(old)
    if not out:
        raise RuntimeError("no Caltrans district answered")
    demoted, probed, unchecked = verify_playlists(out, cache_path or os.path.join(os.getcwd(), ".probe-cache.json"))
    emit(ev="note", src="caltrans", demoted=demoted, probed=probed, unchecked=unchecked, failed_districts=failed,
         msg=f"{demoted} dead live streams shown as snapshots ({probed} probed now, {unchecked} not yet checked)"
             + (f"; districts unavailable: {', '.join(failed)} ({kept} cameras kept from the previous catalog)" if failed else ""))
    return out


def fetch_tfl():
    out = []
    for row in http_json("https://api.tfl.gov.uk/Place/Type/JamCam"):
        props = {p.get("key"): p.get("value") for p in row.get("additionalProperties", [])}
        if str(props.get("available")).lower() == "false":
            continue
        rec = make("tfl", str(row.get("id", "")).replace("JamCams_", ""), row.get("commonName"),
                   row.get("lat"), row.get("lon"), "loop", props.get("videoUrl"),
                   props.get("imageUrl"), place="London, UK", country="GB", refresh=60)
        if rec:
            out.append(rec)
    return out


def fetch_digitraffic():
    out = []
    doc = http_json("https://tie.digitraffic.fi/api/weathercam/v1/stations",
                    headers={"Digitraffic-User": "omarchy-vantage"})
    for f in doc.get("features", []):
        p, g = f.get("properties") or {}, f.get("geometry") or {}
        coords = g.get("coordinates") or []
        presets = [x for x in p.get("presets", []) if x.get("inCollection")]
        if len(coords) < 2 or not presets or p.get("collectionStatus") != "GATHERING":
            continue
        # "kt51_Inkoo" -> road "kt51", place "Inkoo".
        road, _, rest = str(p.get("name", "")).partition("_")
        place = rest.replace("_", " ") or road
        name = f"{place} ({road.upper()})" if rest else place
        rec = make("digitraffic", f.get("id"), name, coords[1], coords[0], "snapshot", None,
                   f"https://weathercam.digitraffic.fi/{presets[0]['id']}.jpg",
                   place=f"{place}, Finland", country="FI", category="weather", refresh=300)
        if rec:
            out.append(rec)
    return out


def fetch_drivebc():
    out = []
    for row in http_json("https://www.drivebc.ca/api/webcams/"):
        if row.get("marked_stale") or row.get("marked_delayed"):
            continue
        coords = (row.get("location") or {}).get("coordinates") or []
        if len(coords) < 2:
            continue
        name = clean(row.get("name_override") or row.get("name"))
        region = clean(row.get("region_name"))
        rec = make("drivebc", row.get("id"), name, coords[1], coords[0], "snapshot", None,
                   f"https://www.drivebc.ca/images/{int(row['id'])}.jpg",
                   place=", ".join(x for x in (region, "BC, Canada") if x), country="CA",
                   refresh=300)
        if rec:
            out.append(rec)
    return out


def fetch_nsw():
    out = []
    for f in http_json("https://www.livetraffic.com/datajson/all-feeds-web.json", timeout=40):
        if f.get("eventCategory") != "liveCams":
            continue
        p, g = f.get("properties") or {}, f.get("geometry") or {}
        coords = g.get("coordinates") or []
        if len(coords) < 2:
            continue
        rec = make("nsw", f.get("id"), p.get("title"), coords[1], coords[0], "snapshot", None,
                   p.get("href"), place="New South Wales, Australia", country="AU", refresh=120)
        if rec:
            out.append(rec)
    return out


def fetch_singapore():
    out = []
    doc = http_json("https://api.data.gov.sg/v1/transport/traffic-images")
    for item in (doc.get("items") or [])[:1]:
        for c in item.get("cameras", []):
            loc = c.get("location") or {}
            rec = make("sgtraffic", c.get("camera_id"), f"Traffic cam {c.get('camera_id')}",
                       loc.get("latitude"), loc.get("longitude"), "snapshot", None, c.get("image"),
                       place="Singapore", country="SG", refresh=60)
            if rec:
                out.append(rec)
    return out


def fetch_youtube(curated_path):
    """Curated 24/7 YouTube live cams. Live video ids rotate, so each curated
    entry stores a channel + title match and the current id is resolved here."""
    ytdlp = shutil.which("yt-dlp") or "/usr/bin/yt-dlp"
    if not os.path.exists(ytdlp):
        raise RuntimeError("yt-dlp not installed")
    with open(curated_path, encoding="utf-8") as fh:
        entries = json.load(fh).get("cams", [])

    channels = sorted({e["channel"] for e in entries if e.get("channel")})

    def list_live(ch):
        cmd = [ytdlp, "--flat-playlist", "--playlist-end", "120", "--no-warnings",
               "--print", "%(id)s\t%(title)s\t%(live_status)s",
               f"https://www.youtube.com/{ch}/streams"]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=75,
                                 env={"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "")})
        except subprocess.TimeoutExpired:
            return ch, None
        rows = []
        for line in res.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[2] == "is_live" and re.fullmatch(r"[A-Za-z0-9_-]{11}", parts[0]):
                rows.append((parts[0], parts[1]))
        return ch, (rows if res.returncode == 0 or rows else None)

    live = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for ch, rows in pool.map(list_live, channels):
            live[ch] = rows

    def toks(s):
        return set(re.findall(r"[a-z0-9]+", str(s).lower()))

    out, used = [], set()
    for e in entries:
        rows = live.get(e.get("channel"))
        vid = None
        if rows:
            live_ids = {rid for rid, _ in rows}
            if e.get("ytId") in live_ids and e["ytId"] not in used:
                vid = e["ytId"]                      # same stream is still live
            else:                                    # id rotated: match by title tokens
                want = toks(e.get("match") or e.get("name"))
                for rid, title in rows:
                    if rid not in used and want and want <= toks(title):
                        vid = rid
                        break
        if not vid and rows is None:
            vid = e.get("ytId")   # channel listing failed: fall back to the seed's last-known id
        if not vid:
            continue
        used.add(vid)
        watch = f"https://www.youtube.com/watch?v={vid}"
        rec = make("yt", e["slug"], e["name"], e.get("lat"), e.get("lon"), "video", watch,
                   f"https://i.ytimg.com/vi/{vid}/mqdefault_live.jpg", place=e.get("place", ""),
                   country=e.get("country", ""), category=e.get("cat", "city"), refresh=60)
        if rec:
            out.append(rec)
    return out


# (id, display name, fetcher, enabled by default, license/attribution note)
def adapters(curated_path, state_dir):
    return [
        ("caltrans", "Caltrans", lambda: fetch_caltrans(os.path.join(state_dir, "probe-cache.json")), True),
        ("tfl", "TfL JamCam", fetch_tfl, True),
        ("digitraffic", "Fintraffic Digitraffic", fetch_digitraffic, True),
        ("drivebc", "DriveBC", fetch_drivebc, True),
        ("nsw", "Live Traffic NSW", fetch_nsw, True),
        ("sgtraffic", "Singapore LTA", fetch_singapore, True),
        ("yt", "YouTube 24/7 (curated)", lambda: fetch_youtube(curated_path), True),
    ]


# ---------------------------------------------------------------------- main

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--curated", default=os.path.join(here, "..", "data", "curated.json"))
    ap.add_argument("--enable", default="", help="comma list of extra/default-off sources to include")
    ap.add_argument("--disable", default="", help="comma list of sources to skip")
    ap.add_argument("--only", default="", help="comma list: run only these sources (debug)")
    args = ap.parse_args()

    on = {s for s in args.enable.split(",") if s}
    off = {s for s in args.disable.split(",") if s}
    only = {s for s in args.only.split(",") if s}

    prev = {}
    try:
        with open(args.out, encoding="utf-8") as fh:
            prev_doc = json.load(fh)
        for c in prev_doc.get("cams", []):
            prev.setdefault(c.get("src"), []).append(c)
    except (OSError, ValueError):
        pass

    PREV.update(prev)
    plan = []
    for sid, label, fn, default in adapters(args.curated, os.path.dirname(os.path.abspath(args.out))):
        if only and sid not in only:
            continue
        if sid in off or not (default or sid in on):
            continue
        plan.append((sid, label, fn))

    results = {}

    def run(item):
        sid, label, fn = item
        t0 = time.time()
        try:
            cams = fn()
            emit(ev="source", src=sid, name=label, status="ok", count=len(cams),
                 secs=round(time.time() - t0, 1))
            return sid, label, cams, None
        except Exception as exc:  # isolation: never let one adapter sink the run
            err = f"{type(exc).__name__}: {exc}"[:160]
            emit(ev="source", src=sid, name=label, status="fail", error=err)
            return sid, label, None, err

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for sid, label, cams, err in pool.map(run, plan):
            results[sid] = (label, cams, err)

    cams_out, src_meta = [], []
    for sid, label, _ in plan:
        label, cams, err = results[sid]
        old_n = len(prev.get(sid, []))
        if cams is not None and old_n >= 50 and len(cams) < old_n * 0.5:
            # Far fewer than last time is almost always an outage, not the cameras going away.
            err = f"only {len(cams)} of {old_n} returned"
            cams = None
        if cams is not None and len(cams) > 0:
            cams_out.extend(cams)
            src_meta.append({"id": sid, "name": label, "count": len(cams), "status": "ok"})
        else:
            old = prev.get(sid, [])
            cams_out.extend(old)
            src_meta.append({"id": sid, "name": label, "count": len(old),
                             "status": "stale" if old else "fail",
                             "error": err or "no cameras returned"})

    if not cams_out:
        emit(ev="done", total=0, error="no cameras from any source")
        return 1

    # De-duplicate by id (a source could repeat a row).
    seen, unique = set(), []
    for c in cams_out:
        if c["id"] not in seen:
            seen.add(c["id"])
            unique.append(c)

    doc = {"v": 1, "built": int(time.time()), "sources": src_meta, "cams": unique}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, args.out)
    emit(ev="done", total=len(unique), path=args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
