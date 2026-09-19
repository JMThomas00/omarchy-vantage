#!/usr/bin/python3
"""Dev-time helper: generate assets/land-dots.json, the dot-matrix land layer.

Rasterizes Natural Earth 1:50m land polygons (public domain,
https://www.naturalearthdata.com) to a 0.1 degree equirectangular mask with
PIL, then samples two families of dot layouts from it:

  sphere  latitude rings whose dot count follows cos(lat), so dots are evenly
          spaced *on the globe* (used by the globe projection)
  grid    a plain lat/lon lattice (used by the flat map, where an even lattice
          is what makes it read as an LED panel)

each at three densities (coarse / mid while moving, fine when idle).
Coordinates are stored as integers in 0.1 degree units: [lat, lon, lat, lon...].
No polygon math happens at runtime. The mask itself is also saved as assets/land-mask.png.

Usage: tools/prep-map.py [path/to/ne_50m_land.geojson]   (downloads if omitted)
"""

import json
import math
import os
import sys
import urllib.request

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "land-dots.json")
OUT_MASK = os.path.join(HERE, "..", "assets", "land-mask.png")
URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_land.geojson"

PX_PER_DEG = 10           # mask resolution: 3600 x 1800
W, H = 360 * PX_PER_DEG, 180 * PX_PER_DEG

SPHERE_STEPS = {"coarse": 2.0, "mid": 1.35, "fine": 0.9}
GRID_STEPS = {"coarse": 2.0, "mid": 1.3, "fine": 0.8}


def load_geojson(path):
    if path:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    with urllib.request.urlopen(URL, timeout=60) as r:
        return json.load(r)


def to_px(lon, lat):
    return ((lon + 180) * PX_PER_DEG, (90 - lat) * PX_PER_DEG)


def build_mask(doc):
    img = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(img)
    for feat in doc["features"]:
        geom = feat["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            draw.polygon([to_px(x, y) for x, y in poly[0]], fill=255)          # exterior
            for hole in poly[1:]:
                draw.polygon([to_px(x, y) for x, y in hole], fill=0)           # lakes etc.
    return img


def is_land(mask, lon, lat):
    x = min(W - 1, max(0, int((lon + 180) * PX_PER_DEG)))
    y = min(H - 1, max(0, int((90 - lat) * PX_PER_DEG)))
    return mask.getpixel((x, y)) > 127


def q(v):
    return int(round(v * 10))


def sample_sphere(mask, step):
    out = []
    rows = int(round(180 / step))
    for i in range(rows):
        lat = -90 + (i + 0.5) * step
        n = max(1, int(round(360 * math.cos(math.radians(lat)) / step)))
        for j in range(n):
            lon = -180 + (j + 0.5) * 360 / n
            if is_land(mask, lon, lat):
                out += [q(lat), q(lon)]
    return out


def sample_grid(mask, step):
    out = []
    rows, cols = int(round(180 / step)), int(round(360 / step))
    for i in range(rows):
        lat = -90 + (i + 0.5) * step
        for j in range(cols):
            lon = -180 + (j + 0.5) * step
            if is_land(mask, lon, lat):
                out += [q(lat), q(lon)]
    return out


def main():
    doc = load_geojson(sys.argv[1] if len(sys.argv) > 1 else None)
    mask = build_mask(doc)
    result = {
        "v": 1,
        "unit": 0.1,
        "source": "Natural Earth 1:50m land (public domain)",
        "sphere": {k: sample_sphere(mask, s) for k, s in SPHERE_STEPS.items()},
        "grid": {k: sample_grid(mask, s) for k, s in GRID_STEPS.items()},
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # the same raster, kept as a 1-bit-ish PNG for the GPU BLOCKS style (shaders/imagery.frag, mode 3)
    mask.point(lambda v: 255 if v > 127 else 0).save(OUT_MASK, optimize=True)
    print(f"wrote {OUT_MASK} ({os.path.getsize(OUT_MASK) // 1024} KB)")
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(result, fh, separators=(",", ":"))
    for fam in ("sphere", "grid"):
        for k, v in result[fam].items():
            print(f"{fam}/{k}: {len(v) // 2} land dots")
    print(f"wrote {OUT} ({os.path.getsize(OUT) // 1024} KB)")


if __name__ == "__main__":
    main()
