# Third-party code and data used by Vantage

Vantage is MIT-licensed (see `LICENSE`). This file records what it builds on.

## Code

### `bin/supervise.sh`

Vendored verbatim from **scoop.uptime-kuma** (MIT):

```
MIT License
Copyright (c) 2026 Patrick Lenz
```

Runs a helper in its own process group and turns one signal into a bounded
TERM-then-KILL for the whole group, confirming the group is gone. Used to
supervise the catalog build (`bin/catalog-build.py`).

### `SupervisedProcess.qml`

Copied from the author's own **Lookout** plugin (MIT, Jordan Thomas), which
wrote it as a companion to the `BoundedProcess.qml` it adapted from
scoop.uptime-kuma. Only the sibling component is used here.

### Design inspiration: Radio Atlas

The two-pane "globe on the left, list and search on the right" layout is
inspired by **Radio Atlas** by Akshar Patel (MIT,
https://github.com/AksharP5/omarchy-radio-atlas), which does the same for radio
stations. **No Radio Atlas code is included**: the projection, dot-matrix
rendering, clustering and interaction code in `Geo.js` and `Globe.qml` was
written from scratch.

## Map data

**Natural Earth** 1:50m land polygons, **public domain**
(https://www.naturalearthdata.com). `tools/prep-map.py` rasterizes them into
the dot grids in `assets/land-dots.json`, and `tools/prep-vector.py` packs 1:110m and simplified 1:50m coastlines (several detail tiers) plus 1:110m / 1:50m boundary
lines into `assets/vector.json` and `assets/vector-max.json` for the Vector style. No polygons are processed at runtime.

**Blue Marble Next Generation** true-colour imagery, NASA Earth Observatory /
NASA GIBS (https://earthdata.nasa.gov/gibs). NASA imagery is **public domain**.
`tools/prep-imagery.py` fetches it as one 4096x2048 equirectangular image
(`assets/satellite.jpg`) for the Satellite style. Imagery courtesy NASA Earth Observatory.

**Landsat WELD** true-colour annual composite (Web-Enabled Landsat Data, NASA / USGS), served by
NASA GIBS. **Public domain.** Streamed at runtime as map tiles when the Satellite style is zoomed in
(`DetailLayer.qml`); never bundled.

**AWS Terrain Tiles** (Terrarium encoding), Amazon Web Services Open Data. Built from SRTM, USGS 3DEP/NED,
GMTED2010, ETOPO1 and other public elevation sources; see
https://github.com/tilezen/joerd/blob/master/docs/attribution.md . Streamed at runtime when the Topo and
Contour styles are zoomed in; never bundled.

**DEM Global Mosaic** global relief including ocean bathymetry, NOAA National Centers for
Environmental Information (https://www.ncei.noaa.gov). US Government work, **public domain**.
`tools/prep-imagery.py` packs it into `assets/elevation.webp` (16-bit elevation split across
two 8-bit channels) for the Topo style.

## Camera data (fetched at runtime, never bundled except the curated seed)

| Source | Terms |
|---|---|
| Caltrans district CCTV | Public data from the California Department of Transportation |
| TfL JamCam | Powered by TfL Open Data. Open Government Licence v3.0; contains OS data (c) Crown copyright and database rights |
| Fintraffic Digitraffic | Source: Fintraffic / digitraffic.fi, licence CC 4.0 BY |
| DriveBC | BC Ministry of Transportation and Transit, Open Government Licence - British Columbia |
| Live Traffic NSW | Transport for NSW, Creative Commons Attribution 4.0 |
| Singapore LTA (data.gov.sg) | Singapore Open Data Licence v1.0 |
| YouTube 24/7 (curated) | Public live streams published by the cameras' own operators. Only the channel, place and coordinates are recorded here, never the video. Played through yt-dlp + mpv |

The same attributions are shown in the plugin's Sources page (`S`).
