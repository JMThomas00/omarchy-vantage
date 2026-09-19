#!/usr/bin/python3
"""Dev-time helper: generate the two whole-planet textures behind the SATELLITE and
TOPO map styles.

  assets/satellite.jpg   NASA Blue Marble Next Generation, true colour, 4096x2048
                         (NASA Earth Observatory / GIBS, public domain)
  assets/elevation.webp  global relief incl. ocean depth, 4096x2048, packed into two
                         8-bit channels so the GPU can decode it exactly:
                             v = R*256 + G          (R = high byte, G = low byte, B unused)
                             elevation_m = v * STEP_M - OFFSET_M
                         Bilinear filtering of R and G separately is exact for this
                         packing (decode is linear), so the shader can sample it freely.
                         (NOAA NCEI DEM Global Mosaic, US Government, public domain)

Both are equirectangular, lon -180..180 left to right, lat 90..-90 top to bottom, and
are fetched at 2x size and area-averaged down so they are not aliased.

Usage: tools/prep-imagery.py [satellite|elevation]     (default: both)
"""

import io
import os
import sys
import urllib.request
from array import array

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")
W, H = 4096, 2048
FETCH_W, FETCH_H = W * 2, H * 2

SAT_URL = ("https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1"
           "&LAYERS=BlueMarble_NextGeneration&SRS=EPSG:4326&BBOX=-180,-90,180,90"
           "&WIDTH=%d&HEIGHT=%d&FORMAT=image/jpeg&STYLES=" % (FETCH_W, FETCH_H))
DEM_URL = ("https://gis.ngdc.noaa.gov/arcgis/rest/services/DEM_mosaics/DEM_global_mosaic/ImageServer/exportImage"
           "?bbox=-180,-90,180,90&bboxSR=4326&size=%d,%d&imageSR=4326&format=tiff&pixelType=S16"
           "&interpolation=RSP_BilinearInterpolation&f=image" % (FETCH_W, FETCH_H))

OFFSET_M = 11000.0    # so the deepest trench (~-10.9 km) packs to a positive value
STEP_M = 10.0         # metres per packed unit: 10 * 65535 covers far more than -11000 .. +9000;
                      # coarser steps compress much better and contours/shading do not need finer


def fetch(url, timeout=240):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def satellite():
    im = Image.open(io.BytesIO(fetch(SAT_URL))).convert("RGB")
    im = im.resize((W, H), Image.BOX)
    out = os.path.join(ASSETS, "satellite.jpg")
    im.save(out, "JPEG", quality=82, optimize=True, progressive=True)
    print("satellite.jpg   %d KB" % (os.path.getsize(out) // 1024))


def elevation():
    src = Image.open(io.BytesIO(fetch(DEM_URL)))
    if src.size != (FETCH_W, FETCH_H):
        raise SystemExit("unexpected DEM size %r" % (src.size,))
    src = src.convert("I").resize((W, H), Image.BOX)
    vals = array("i", src.tobytes()) if array("i").itemsize == 4 else None
    hi = bytearray(W * H)
    lo = bytearray(W * H)
    k = 1.0 / STEP_M
    for i, e in enumerate(vals):
        v = int((e + OFFSET_M) * k + 0.5)
        v = 0 if v < 0 else (65535 if v > 65535 else v)
        hi[i] = v >> 8
        lo[i] = v & 255
    r = Image.frombytes("L", (W, H), bytes(hi))
    g = Image.frombytes("L", (W, H), bytes(lo))
    b = Image.new("L", (W, H), 0)
    out = os.path.join(ASSETS, "elevation.webp")
    Image.merge("RGB", (r, g, b)).save(out, "WEBP", lossless=True, quality=100, method=4)
    print("elevation.webp  %d KB   (min %d m, max %d m)" % (os.path.getsize(out) // 1024, min(vals), max(vals)))


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    os.makedirs(ASSETS, exist_ok=True)
    if what in ("all", "satellite"):
        satellite()
    if what in ("all", "elevation"):
        elevation()


if __name__ == "__main__":
    main()
