#!/usr/bin/python3
"""Fetch map tiles for the satellite / topo / contour styles into a disk cache, in parallel.

Usage: tiles.py <sat|elev> <z:x:y> [<z:x:y> ...]

Tiles are fetched in the order given (the caller sends the middle of the screen first), 24 at a
time, and each one is reported on stdout the moment it is ready:

    ok <z:x:y> <relative/path/under/the/cache>
    miss <z:x:y>                     (the server has no such tile, e.g. no data over open ocean)

Why not let QML load them: Qt's network stack keeps only 6 requests in flight and has no
persistent cache, so a zoomed-in view took seconds to sharpen and every visit re-downloaded it.
Here revisits are served from ~/.cache/vantage/tiles (instant, and offline), a 404 is remembered
for a week so it is not asked again, and the cache is trimmed to about 400 MB.

Strict on purpose: only the two fixed hosts below are contacted, tile numbers must be integers in
range, responses must be a real JPEG / PNG under 1 MB, and files are written atomically.
"""

import concurrent.futures
import os
import re
import sys
import time
import urllib.error
import urllib.request

UA = "omarchy-vantage/0.4 (map tile cache)"
WORKERS = 24
MAX_TILE_BYTES = 1_000_000
MISS_TTL = 7 * 86400
CACHE_LIMIT = 400 * 1024 * 1024

SOURCES = {
    "sat": ("jpg", "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/2000-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpg", 12, b"\xff\xd8\xff"),
    "elev": ("png", "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png", 11, b"\x89PNG"),
}


def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "vantage", "tiles")


def say(*parts):
    print(" ".join(parts), flush=True)


def fetch_one(kind, key, root):
    ext, url_t, max_z, magic = SOURCES[kind]
    z, x, y = (int(v) for v in key.split(":"))
    rel = f"{kind}/{z}/{x}_{y}.{ext}"
    path = os.path.join(root, rel)
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        try:
            os.utime(path, None)                       # LRU: a used tile is not the oldest
        except OSError:
            pass
        return key, rel
    miss = path + ".miss"
    try:
        if time.time() - os.path.getmtime(miss) < MISS_TTL:
            return key, None
    except OSError:
        pass
    url = url_t.format(z=z, x=x, y=y)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = r.read(MAX_TILE_BYTES + 1)
            if len(data) > MAX_TILE_BYTES or not data.startswith(magic):
                return key, None
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = f"{path}.{os.getpid()}.tmp"
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)
            return key, rel
        except urllib.error.HTTPError as exc:
            if exc.code in (403, 404):                 # definitive: remember it
                try:
                    os.makedirs(os.path.dirname(miss), exist_ok=True)
                    open(miss, "w").close()
                except OSError:
                    pass
                return key, None
            last = exc
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            last = exc
        time.sleep(0.4)
    return key, None


def trim(root):
    """Keep the cache under CACHE_LIMIT by removing the least recently used tiles."""
    files, total = [], 0
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            try:
                st = os.stat(p)
            except OSError:
                continue
            files.append((st.st_mtime, st.st_size, p))
            total += st.st_size
    if total <= CACHE_LIMIT:
        return
    files.sort()
    for _, size, p in files:
        try:
            os.remove(p)
        except OSError:
            continue
        total -= size
        if total <= CACHE_LIMIT * 0.8:
            break


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in SOURCES:
        sys.exit("usage: tiles.py <sat|elev> <z:x:y> ...")
    kind = sys.argv[1]
    max_z = SOURCES[kind][2]
    keys = []
    for k in sys.argv[2:400]:
        m = re.fullmatch(r"([0-9]{1,2}):([0-9]{1,8}):([0-9]{1,8})", k)
        if not m:
            continue
        z, x, y = (int(v) for v in m.groups())
        if z > max_z or x >= 2 ** z or y >= 2 ** z:
            continue
        keys.append(k)
    root = cache_root()
    os.makedirs(root, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        futs = [pool.submit(fetch_one, kind, k, root) for k in keys]
        for f in concurrent.futures.as_completed(futs):
            key, rel = f.result()
            say("ok", key, rel) if rel else say("miss", key)
    if os.environ.get("VANTAGE_TILES_NO_TRIM") != "1" and int(time.time()) % 10 == 0:
        trim(root)                                     # every ~10th run: cheap enough, keeps the cache bounded


if __name__ == "__main__":
    main()
