#!/usr/bin/python3
"""Dev-time helper: generate assets/vector.json, the line-art map layers used by
the VECTOR map style.

Natural Earth (public domain, https://www.naturalearthdata.com):
  coast.xlo / lo   1:110m coastline, simplified / as-is   (cheapest; drawn while moving)
  coast.mid / hi   1:50m coastline, Douglas-Peucker        (idle detail)
  coast.max        1:50m at a fine tolerance               (vector-max.json, on demand)
  borders          1:110m land boundary lines (1:50m in vector-max.json)

Every polyline is stored as packed integers in 0.1 degree units:
[lat, lon, lat, lon, ...]. Nothing is computed from polygons at runtime.

Usage: tools/prep-vector.py
"""

import json
import math
import os
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "vector.json")
OUT_MAX = os.path.join(HERE, "..", "assets", "vector-max.json")
BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
# Coastline resolution ladder, one tier per VECTOR DETAIL level. Douglas-Peucker tolerance in degrees.
XLO_TOL = 0.5        # 110m coastline, heavily simplified: used while moving on LOW / MEDIUM
MID_TOL = 0.15       # 50m coastline, ~15 km
HI_TOL = 0.06        # 50m coastline, ~6 km (the default HIGH level)
MAX_TOL = 0.02       # 50m coastline, ~2 km (HIGHEST; separate file, loaded only when chosen)
BORDER_HI_TOL = 0.03 # 50m boundary lines for HIGHEST


def fetch(name):
    with urllib.request.urlopen(BASE + name + ".geojson", timeout=90) as r:
        return json.load(r)


def lines_of(doc):
    for feat in doc["features"]:
        g = feat["geometry"]
        if g["type"] == "LineString":
            yield g["coordinates"]
        elif g["type"] == "MultiLineString":
            yield from g["coordinates"]
        elif g["type"] == "Polygon":
            yield from g["coordinates"]
        elif g["type"] == "MultiPolygon":
            for poly in g["coordinates"]:
                yield from poly


def dp(points, tol):
    """Iterative Douglas-Peucker on [lon, lat] points.

    Closed rings (first == last, i.e. every island) need care: the chord from
    the first point to the last has zero length, so every vertex is "0 away"
    and the whole ring would collapse. Split the ring at the vertex farthest
    from its start and simplify the two halves instead.
    """
    n = len(points)
    if n < 3:
        return points
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = []
    if points[0] == points[-1] and n > 3:
        ax, ay = points[0]
        far = max(range(1, n - 1), key=lambda i: (points[i][0] - ax) ** 2 + (points[i][1] - ay) ** 2)
        keep[far] = True
        stack += [(0, far), (far, n - 1)]
    else:
        stack.append((0, n - 1))
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy) or 1e-12
        best, idx = -1.0, -1
        for i in range(a + 1, b):
            px, py = points[i]
            d = abs(dy * (px - ax) - dx * (py - ay)) / norm
            if d > best:
                best, idx = d, i
        if best > tol:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for p, k in zip(points, keep) if k]


def pack(line):
    out = []
    for lon, lat in line:
        out += [int(round(lat * 10)), int(round(lon * 10))]
    return out


def extent(line):
    """Largest span (degrees) of a polyline in lat or lon."""
    lons = [p[0] for p in line]
    lats = [p[1] for p in line]
    return max(max(lons) - min(lons), max(lats) - min(lats))


def simplified(lines, tol, min_extent):
    """Simplify with Douglas-Peucker and drop islands smaller than min_extent degrees:
    at a coarse tolerance a tiny island collapses to a 2-3 vertex stub that draws as a
    stray slash, so it is better omitted from that tier."""
    out = [pack(dp(l, tol)) for l in lines if len(l) >= 2 and extent(l) >= min_extent]
    return [l for l in out if len(l) >= 4]


def main():
    c110 = list(lines_of(fetch("ne_110m_coastline")))
    c50 = list(lines_of(fetch("ne_50m_coastline")))
    doc = {
        "v": 2, "unit": 0.1, "source": "Natural Earth (public domain)",
        "coast": {
            "xlo": simplified(c110, XLO_TOL, 1.2),
            "lo": [pack(l) for l in c110 if len(l) >= 2],
            "mid": simplified(c50, MID_TOL, 0.3),
            "hi": simplified(c50, HI_TOL, 0.1),
        },
        "borders": [pack(l) for l in lines_of(fetch("ne_110m_admin_0_boundary_lines_land")) if len(l) >= 2],
    }
    mx = {
        "v": 2, "unit": 0.1, "source": "Natural Earth (public domain)",
        "coast": {"max": simplified(c50, MAX_TOL, 0.04)},
        "borders": simplified(list(lines_of(fetch("ne_50m_admin_0_boundary_lines_land"))), BORDER_HI_TOL, 0.0),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    for path, d in ((OUT, doc), (OUT_MAX, mx)):
        with open(path, "w") as fh:
            json.dump(d, fh, separators=(",", ":"))
    for k, v in list(doc["coast"].items()) + [("borders(110m)", doc["borders"])] + \
                list(mx["coast"].items()) + [("borders(50m)", mx["borders"])]:
        print(f"{k:14} {len(v):5} polylines, {sum(len(x) // 2 for x in v):6} vertices")
    print(f"wrote {OUT} ({os.path.getsize(OUT) // 1024} KB) and {OUT_MAX} ({os.path.getsize(OUT_MAX) // 1024} KB)")


if __name__ == "__main__":
    main()
