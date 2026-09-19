#!/usr/bin/python3
"""Dev-time helper: (re)generate data/curated.json, the bundled seed of curated
24/7 YouTube live cams. NOT used at runtime and not needed by users.

For each operator channel below it lists the channel's currently-live streams
with yt-dlp, keeps the ones a rule can place on the map, and writes
data/curated.json. Placement is deliberately conservative: coordinates come
from (1) a hand-checked OVERRIDES table, (2) a channel-wide default for
single-site operators, or (3) for EarthCam's "Name (City, ST)" titles, a
Nominatim lookup (cached, 1 req/s per their usage policy). Anything that can't
be placed is printed under "UNPLACED" instead of being guessed.

Usage:  tools/curate-youtube.py [--no-geocode] [--dry-run]

Runtime resolution (bin/catalog-build.py) re-lists each channel and matches by
`match` (title substring) because live video ids rotate; `ytId` is only the
fallback when a channel listing fails.
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "data", "curated.json")
GEO_CACHE = os.path.join(HERE, ".geocode-cache.json")

# key, channel id, category, max entries, title regexes to drop
CHANNELS = [
    ("earthcam", "UC6qrG3W8SMK0jior2olka3g", "city", 60, []),
    ("usgs", "UCeXH8GZyV3sVqAr45AvupOA", "volcano", 10, [r"was_live"]),
    ("afartv", "UCaG0IHN1RMOZ4-U3wDXAkwA", "volcano", 40,
     [r"VR180", r"Members-Only", r"Multi-cams", r"Episode", r"\(Cam [BCDE]\)", r"CAM B", r"CAM C",
      r"Overview Camera", r"NASA Live"]),
    ("explore", "UC-2KSeUU5SMCX6XLRD-AEvw", "wildlife", 20, []),
    ("exploreoceans", "UCSyg9cb3Iq-NtlbxqNB9wGw", "wildlife", 20,
     [r"Back Channel", r"Front-of-Dock", r"Edge-of-Wall", r"Top-of-Wall", r"Back-of-Dock",
      r"Sandy Channel", r"Above Water"]),
    ("africam", "UCuoNAKa3P0QR1Lw9QdpmoVg", "wildlife", 40, [r"Lisbon Falls", r"Rolling"]),
    ("montereybay", "UCnM5iMGiKsZg-iOlIO2ZkdQ", "wildlife", 12, []),
    ("vanaquarium", "UCbzl-qtfTKY9QNgtnqmuyBw", "wildlife", 4, []),
    ("livenorway", "UCagckRRHeGkG7iwPl91hUpg", "harbor", 20, [r"^Port og", r"Vindøl", r"^Eide", r"Nordfjordhjort"]),
    ("webcamsydney", "UCLav_kTu9PmAEChvGyrPbhQ", "city", 4, []),
    ("duluth", "UCzkaQrI9-nSv373EvK5p0SQ", "harbor", 25, [r"Cargo Connect", r"Solglimt"]),
    ("tokyoviews", "UCaaSp7JYkACHR-Sr-p3OHeQ", "city", 6, [r"PORTRAIT"]),
    ("levi", "UC1HDQ1Q5nVHYF8e7dL4E-pw", "mountain", 12, []),
    ("starlapland", "UC-whuqv4HIi1O9hh9CHpPJg", "sky", 8, [r"backup", r"River Live"]),
    ("namibiacam", "UC9X6gGKDv2yhMoofoeS7-Gg", "wildlife", 5, []),
    ("bostonmaine", "UC8gbWbcNNyb5-NIXvFklkOA", "city", 90,
     [r"Around the World", r"Fall Colors", r"Tuscany", r"Montifalco", r"Meteorologist", r"Stars", r"McAdam", r"Chester Railway"]),
    ("venice", "UCMpn1qLudF-zb4M4bqxLIbw", "city", 30, []),
    ("moodygardens", "UCKDM9GYy91kKpNOGZVS0ZFg", "wildlife", 4, []),
    ("kabukicho", "UCCLnJzwda_Kcdkok3et7n0A", "city", 4, []),
]

# Channel-wide default for operators that run cams at one site.
DEFAULT_LOC = {
    "usgs": (19.4069, -155.2835, "Kīlauea, Hawaiʻi", "US"),
    "montereybay": (36.6183, -121.9018, "Monterey Bay Aquarium, CA", "US"),
    "vanaquarium": (49.3009, -123.1305, "Vancouver Aquarium, BC", "CA"),
    "webcamsydney": (-33.8568, 151.2153, "Sydney Harbour, Australia", "AU"),
    "levi": (67.8057, 24.8023, "Levi, Finland", "FI"),
    "moodygardens": (29.2743, -94.8581, "Moody Gardens, Galveston, TX", "US"),
    "kabukicho": (35.6949, 139.7028, "Kabukichō, Tokyo", "JP"),
}

# (regex on "<key>|<title>", lat, lon, place, country) -- first match wins.
OVERRIDES = [
    (r"earthcam\|.*Times Square", 40.758, -73.9855, "Times Square, New York, NY", "US"),
    (r"earthcam\|.*Madison, Indiana", 38.7359, -85.38, "Madison, IN", "US"),
    (r"earthcam\|.*Seaside Heights", 39.944, -74.073, "Seaside Heights, NJ", "US"),
    (r"earthcam\|.*New Orleans", 29.9584, -90.0644, "French Quarter, New Orleans, LA", "US"),
    (r"earthcam\|.*Giraffe", 34.8526, -82.394, "Greenville, SC", "US"),
    (r"bostonmaine\|.*Moosehead|bostonmaine\|.*Rockwood", 45.6, -69.75, "Moosehead Lake, ME", "US"),
    (r"bostonmaine\|.*Acadia", 44.34, -68.27, "Acadia National Park, ME", "US"),
    (r"bostonmaine\|.*Fenway", 42.3467, -71.0972, "Fenway Park, Boston, MA", "US"),
    (r"bostonmaine\|.*Monadnock", 42.8595, -72.1082, "Mount Monadnock, NH", "US"),
    (r"bostonmaine\|.*Block Island", 41.2, -71.55, "Block Island, RI", "US"),
    (r"bostonmaine\|.*Barnstable", 41.7003, -70.3002, "Barnstable, MA", "US"),
    (r"bostonmaine\|.*Kancamagus", 44.02, -71.5, "Kancamagus Highway, NH", "US"),
    # Duluth, MN harbor operator
    (r"duluth\|.*(Split Rock)", 47.2003, -91.3671, "Split Rock Lighthouse, MN", "US"),
    (r"duluth\|.*(Two Harbors)", 47.0227, -91.6707, "Two Harbors, MN", "US"),
    (r"duluth\|.*(Silver Bay)", 47.2941, -91.2565, "Silver Bay, MN", "US"),
    (r"duluth\|.*(Wisconsin Point)", 46.7217, -92.0072, "Superior, WI", "US"),
    (r"duluth\|", 46.7867, -92.1005, "Duluth, MN", "US"),
    # explore.org
    (r"explore\|.*Brooks Falls", 58.5547, -155.7813, "Katmai National Park, AK", "US"),
    (r"explore\|.*Anan Bear", 56.1841, -131.8873, "Anan Creek, Tongass NF, AK", "US"),
    (r"explore\|.*Tembe", -26.9833, 32.4167, "Tembe Elephant Park, South Africa", "ZA"),
    (r"explore\|.*Manatee", 28.7997, -82.5926, "Homosassa Springs, FL", "US"),
    (r"explore\|.*Decorah", 43.3033, -91.7850, "Decorah, IA", "US"),
    (r"explore\|.*Wolf Center", 47.9019, -91.8657, "Ely, MN", "US"),
    (r"exploreoceans\|.*Silver Springs", 29.2166, -82.0517, "Silver Springs, FL", "US"),
    (r"exploreoceans\|.*Utopia", 16.0908, -86.8967, "Utila, Honduras", "HN"),
    (r"exploreoceans\|.*Anacapa", 34.0089, -119.4, "Channel Islands NP, CA", "US"),
    (r"exploreoceans\|.*Catalina", 33.4472, -118.4847, "Catalina Island, CA", "US"),
    # Live Norway
    (r"livenorway\|.*Selje", 62.0464, 5.3517, "Selje, Norway", "NO"),
    (r"livenorway\|.*Nordfjordeid", 61.9, 6.0, "Nordfjordeid, Norway", "NO"),
    (r"livenorway\|.*Måløy", 61.9358, 5.1131, "Måløy, Norway", "NO"),
    (r"livenorway\|.*Kråkenes", 62.0343, 4.9966, "Kråkenes Lighthouse, Norway", "NO"),
    (r"livenorway\|.*Hjørundfjord", 62.2, 6.5, "Hjørundfjorden, Norway", "NO"),
    (r"livenorway\|.*Stavanger", 58.9718, 5.7307, "Stavanger, Norway", "NO"),
    (r"livenorway\|.*Smøla", 63.4, 8.0, "Smøla, Norway", "NO"),
    (r"livenorway\|.*Hammerfest", 70.6634, 23.6821, "Hammerfest, Norway", "NO"),
    (r"livenorway\|.*Bud og", 62.9042, 6.9101, "Bud, Hustadvika, Norway", "NO"),
    # Starlapland aurora cams
    (r"starlapland\|.*Kilpisj", 69.0489, 20.7913, "Kilpisjärvi, Finland", "FI"),
    (r"starlapland\|.*Sodankyl", 67.4189, 26.5925, "Sodankylä, Finland", "FI"),
    (r"starlapland\|.*Levi", 67.8057, 24.8023, "Levi, Finland", "FI"),
    (r"starlapland\|.*Kalajoki", 64.2597, 23.9497, "Kalajoki, Finland", "FI"),
    # Tokyo
    (r"tokyoviews\|.*Odaiba", 35.6272, 139.7752, "Odaiba, Tokyo", "JP"),
    (r"tokyoviews\|", 35.6364, 139.7635, "Tokyo Bay, Japan", "JP"),
    # Namibia
    (r"namibiacam\|.*Okaukuejo", -19.1728, 15.9163, "Etosha National Park, Namibia", "NA"),
    (r"namibiacam\|.*Namib Desert", -24.73, 15.29, "Namib Desert, Namibia", "NA"),
    # Boston & Maine Live: only clearly single-site cams
    (r"bostonmaine\|.*Boston Weather Cam", 42.3601, -71.0589, "Boston, MA", "US"),
    (r"bostonmaine\|.*Katahdin", 45.9044, -68.9213, "Mount Katahdin, ME", "US"),
    (r"bostonmaine\|.*Big Moose", 45.6, -69.7, "Big Moose Mountain, ME", "US"),
    # Venice operators
    (r"venice\|.*Ca' Angeli", 45.4358, 12.3222, "Grand Canal, Venice", "IT"),
    (r"venice\|.*Fenice", 45.4335, 12.3335, "Teatro La Fenice, Venice", "IT"),
    (r"venice\|.*San Marco Basin", 45.4297, 12.3437, "St Mark's Basin, Venice", "IT"),
    (r"venice\|.*Bacino di San Marco", 45.4331, 12.3552, "Bacino di San Marco, Venice", "IT"),
    (r"venice\|.*Scalzi", 45.4419, 12.3206, "Scalzi Bridge, Venice", "IT"),
    (r"venice\|.*Chioggia", 45.2158, 12.3053, "Sottomarina, Chioggia", "IT"),
    (r"venice\|.*Jesolo", 45.4966, 12.6469, "Jesolo Lido, Italy", "IT"),
    (r"venice\|.*Guglie", 45.4457, 12.3283, "Ponte delle Guglie, Venice", "IT"),
    (r"venice\|.*Santa Maria Formosa", 45.4372, 12.3444, "Campo Santa Maria Formosa, Venice", "IT"),
    (r"venice\|.*San Cassiano", 45.4407, 12.3335, "Grand Canal, Venice", "IT"),
    # afarTV single-site volcano / nature cams
    (r"afartv\|.*Reventador", -0.0777, -77.6565, "El Reventador, Ecuador", "EC"),
    (r"afartv\|.*Iceland Volcano", 63.87, -22.44, "Reykjanes, Iceland", "IS"),
    (r"afartv\|.*Semeru", -8.1077, 112.9224, "Semeru, Java, Indonesia", "ID"),
    (r"afartv\|.*Kanlaon", 10.4125, 123.1323, "Kanlaon, Philippines", "PH"),
    (r"afartv\|.*Popocat", 19.0225, -98.6278, "Popocatépetl, Mexico", "MX"),
    (r"afartv\|.*Ilulissat|afartv\|.*Iceberg", 69.2167, -51.1, "Ilulissat, Greenland", "GL"),
    (r"afartv\|.*Santa Maria", 14.7569, -91.5519, "Santiaguito, Guatemala", "GT"),
    (r"afartv\|.*Etna", 37.751, 14.9934, "Mount Etna, Sicily", "IT"),
    (r"afartv\|.*Cape Canaveral", 28.3922, -80.6077, "Cape Canaveral, FL", "US"),
    (r"afartv\|.*Napili", 20.9942, -156.6664, "Napili Bay, Maui, HI", "US"),
    (r"afartv\|.*Fuego", 14.4747, -90.8806, "Volcán de Fuego, Guatemala", "GT"),
    (r"afartv\|.*Humpback", 20.85, -156.65, "Maui, Hawaiʻi", "US"),
    (r"afartv\|.*Sangay", -2.0027, -78.3411, "Sangay, Ecuador", "EC"),
    (r"afartv\|.*Merapi", -7.5407, 110.4457, "Merapi, Indonesia", "ID"),
    (r"afartv\|.*Bulusan", 12.77, 124.05, "Bulusan, Philippines", "PH"),
    (r"afartv\|.*Mayon", 13.2569, 123.6856, "Mayon, Philippines", "PH"),
    (r"afartv\|.*Georgia", 49.35, -123.75, "Strait of Georgia, BC", "CA"),
    (r"afartv\|.*Kilauea|afartv\|.*Kīlauea", 19.4069, -155.2835, "Kīlauea, Hawaiʻi", "US"),
    (r"afartv\|.*SpaceX", 25.9967, -97.1553, "Starbase, TX", "US"),
    # Africam (region-level; approximate on purpose)
    (r"africam\|.*Angama Amboseli", -2.6527, 37.2606, "Amboseli, Kenya", "KE"),
    (r"africam\|.*Angama Mara", -1.3, 35.0, "Maasai Mara, Kenya", "KE"),
    (r"africam\|.*Mara River", -1.5, 35.0, "Mara River, Kenya/Tanzania", "KE"),
    (r"africam\|.*Tortilis", -2.66, 37.25, "Amboseli, Kenya", "KE"),
    (r"africam\|.*Mahali Mzuri", -1.4, 35.2, "Maasai Mara, Kenya", "KE"),
    (r"africam\|.*Finch Hattons", -3.06, 38.28, "Tsavo West, Kenya", "KE"),
    (r"africam\|.*ol Donyo", -2.7, 37.5, "Chyulu Hills, Kenya", "KE"),
    (r"africam\|.*Serengeti", -2.33, 34.83, "Serengeti, Tanzania", "TZ"),
    (r"africam\|.*Ulusaba", -24.78, 31.42, "Sabi Sand, South Africa", "ZA"),
    (r"africam\|.*Nkorho", -24.8, 31.5, "Sabi Sand, South Africa", "ZA"),
    (r"africam\|.*Simbavati", -24.3, 31.3, "Timbavati, South Africa", "ZA"),
    (r"africam\|.*Kings Camp", -24.35, 31.35, "Timbavati, South Africa", "ZA"),
    (r"africam\|.*Jabulani", -24.5, 31.0, "Kapama, South Africa", "ZA"),
    (r"africam\|.*Skukuza|africam\|.*Shalati", -24.9965, 31.5904, "Kruger NP, South Africa", "ZA"),
    (r"africam\|.*Tau Game", -24.75, 26.3, "Madikwe, South Africa", "ZA"),
    (r"africam\|.*Tembe", -26.9833, 32.4167, "Tembe Elephant Park, South Africa", "ZA"),
    (r"africam\|.*Hwange|africam\|.*Linkwasha|africam\|.*Deteema|africam\|.*Camelthorn", -18.9, 26.6, "Hwange, Zimbabwe", "ZW"),
    (r"africam\|.*Victoria Falls", -17.93, 25.83, "Victoria Falls, Zimbabwe", "ZW"),
    (r"africam\|.*Zambezi", -17.9, 25.85, "Zambezi River", "ZW"),
    (r"africam\|.*Serondella", -17.8, 25.15, "Chobe, Botswana", "BW"),
    (r"africam\|.*Senyati", -18.5, 25.6, "Pandamatenga, Botswana", "BW"),
    (r"africam\|.*Jack", -20.7, 25.5, "Makgadikgadi, Botswana", "BW"),
    (r"africam\|.*Meno a Kwena", -20.4, 25.0, "Makgadikgadi, Botswana", "BW"),
    (r"africam\|.*Onguma", -18.87, 17.02, "Onguma, Namibia", "NA"),
    (r"africam\|.*Ol Pejeta", 0.0, 36.9, "Ol Pejeta, Kenya", "KE"),
    (r"africam\|.*Roy.s Dam", -24.8, 31.5, "Sabi Sand, South Africa", "ZA"),
    (r"africam\|.*Greater Kruger", -24.5, 31.4, "Greater Kruger, South Africa", "ZA"),
    (r"africam\|.*Selinda", -18.6, 23.6, "Selinda Reserve, Botswana", "BW"),
    (r"africam\|.*Boteti", -20.5, 24.5, "Boteti River, Botswana", "BW"),
    (r"venice\|.*Rialto", 45.438, 12.3359, "Rialto Bridge, Venice", "IT"),
    (r"venice\|.*Pausania|venice\|.*Dorsoduro", 45.4322, 12.3221, "Dorsoduro, Venice", "IT"),
    (r"venice\|.*St\. Mark", 45.4297, 12.3437, "St Mark's Basin, Venice", "IT"),
]

TITLE_JUNK = [
    r"^EarthCam Live:?\s*", r"\bLive Now:?\s*", r"\bEN DIRECTO:?\s*", r"\bLIVE:?\b", r"\b24/7\b",
    r"\bin 4K( Ultra[- ]HD| UHD)?\b", r"\b4K\b", r"\s*powered by EXPLORE\.org", r"\bCAM [A-Z]\b",
    r"\bLive (Stream(ing)?|Webcam|Wildlife Camera|Camera|Cam)\b", r"\bFull HD\b",
]


def clean_title(t):
    s = t
    s = re.sub(r"^\s*\[([^\]]+)\]\s*", r"\1 · ", s)            # "[V1cam] Kīlauea" -> "V1cam · Kīlauea"
    s = s.split(" | ")[0]                                         # "Name | Live Wildlife Camera" -> "Name"
    for pat in TITLE_JUNK:
        s = re.sub(pat, " ", s, flags=re.I)
    s = re.sub(r"^[^\w(]+", "", s)                                # leading emoji / bullets
    s = re.sub(r"^(?:Safari\s+)?from\s+(?:the\s+)?", "", s, flags=re.I)   # "LIVE from the Serengeti" -> "Serengeti"
    s = re.sub(r"\s+[-–—]\s+(Stream|Streaming|Webcam|Live|View from|Instant|Full).*$", "", s, flags=re.I)
    s = re.sub(r"[^\x00-\u02ff\u1e00-\u1eff\u2010-\u2027]+", " ", s)   # drop CJK tails etc.
    s = re.sub(r"\(\s*\)", "", s)
    s = re.sub(r"\s+", " ", s).strip(" -–—:|·,")
    return s[:80] or t.strip()[:80]


def slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:48] or "cam"


def list_live(cid, limit):
    cmd = ["yt-dlp", "--flat-playlist", "--playlist-end", "120", "--no-warnings", "--print",
           "%(id)s\t%(title)s\t%(live_status)s", f"https://www.youtube.com/channel/{cid}/streams"]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    rows = []
    for line in res.stdout.splitlines():
        p = line.split("\t")
        if len(p) == 3 and p[2] == "is_live" and re.fullmatch(r"[A-Za-z0-9_-]{11}", p[0]):
            rows.append((p[0], p[1]))
    return rows


class Geocoder:
    def __init__(self, enabled):
        self.enabled = enabled
        try:
            with open(GEO_CACHE, encoding="utf-8") as fh:
                self.cache = json.load(fh)
        except (OSError, ValueError):
            self.cache = {}
        self._last = 0.0

    def lookup(self, q):
        if q in self.cache:
            return self.cache[q]
        if not self.enabled:
            return None
        wait = 1.1 - (time.time() - self._last)
        if wait > 0:
            time.sleep(wait)
        url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
            {"q": q, "format": "jsonv2", "limit": 1, "accept-language": "en"})
        req = urllib.request.Request(url, headers={"User-Agent": "omarchy-vantage-curation/0.1"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.load(r)
        except Exception:
            data = []
        self._last = time.time()
        hit = None
        if data:
            hit = [float(data[0]["lat"]), float(data[0]["lon"]), data[0].get("display_name", "")]
        self.cache[q] = hit
        with open(GEO_CACHE, "w", encoding="utf-8") as fh:
            json.dump(self.cache, fh, ensure_ascii=False, indent=0)
        return hit


def place_earthcam(title, geo, key="earthcam"):
    """'Abbey Road Crossing (London, England)' -> try landmark+city, city, landmark."""
    core = clean_title(title)
    m = re.search(r"\(([^)]+)\)\s*$", core)
    paren = m.group(1).strip() if m else ""
    main = re.sub(r"\s*\([^)]*\)\s*$", "", core).strip()
    main = re.sub(r"\bCam\b", "", main).strip()
    queries = [f"{main}, {paren}"] if paren else []
    queries += ([paren] if paren else []) + [main]
    if key == "bostonmaine":
        # "Bar Harbor, Maine - North View - Bar Harbor Inn" -> "Bar Harbor, Maine"
        head = re.split(r"\s+[-–—]\s+|\s+LIVE\b|\s+US\b|\s+USA\b", core)[0].strip(" ,")
        queries = [head] + ([f"{main}"] if main != head else [])
    for q in queries:
        hit = geo.lookup(q)
        if hit:
            disp = hit[2].split(",")
            parts = [x.strip() for x in ([disp[0]] + disp[-3:-1] if len(disp) > 3 else disp)]
            place = ", ".join(x for x in parts if x and not re.search(r"\d{4,}", x))
            return hit[0], hit[1], paren or place, "", q
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-geocode", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    geo = Geocoder(not args.no_geocode)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        listings = list(pool.map(lambda c: (c, list_live(c[1], c[3])), CHANNELS))

    cams, unplaced = [], []
    for (key, cid, cat, cap, drops), rows in listings:
        n = 0
        for vid, title in rows:
            if n >= cap:
                break
            if any(re.search(d, title, re.I) for d in drops) or re.search(r"\b(Archive \d{4}-\d\d|SNEAK PEEK)", title, re.I):
                continue
            name = clean_title(title)
            loc = None
            for pat, lat, lon, place, cc in OVERRIDES:
                if re.search(pat, f"{key}|{title}", re.I):
                    loc = (lat, lon, place, cc)
                    break
            if not loc and key in DEFAULT_LOC:
                loc = DEFAULT_LOC[key]
            if not loc and key in ("earthcam", "bostonmaine"):
                g = place_earthcam(title, geo, key)
                if g and key == "bostonmaine" and not (40.5 <= g[0] <= 47.6 and -74.5 <= g[1] <= -66.5):
                    print(f"  rejected (outside New England): {name!r} -> {g[0]:.2f},{g[1]:.2f}", file=sys.stderr)
                    g = None
                if g:
                    loc = (g[0], g[1], g[2], "")
                    print(f"  geocode: {name!r:60} -> {g[0]:.3f},{g[1]:.3f}  via {g[4]!r}", file=sys.stderr)
            if not loc:
                unplaced.append(f"{key}: {title}")
                continue
            lat, lon, place, cc = loc
            cams.append({
                "slug": f"{key}-{slugify(name)}", "name": name, "place": place, "country": cc,
                "lat": lat, "lon": lon, "cat": cat, "channel": f"channel/{cid}",
                "match": name.lower()[:60], "ytId": vid,
            })
            n += 1

    # unique slugs
    seen = {}
    for c in cams:
        k = c["slug"]
        seen[k] = seen.get(k, 0) + 1
        if seen[k] > 1:
            c["slug"] = f"{k}-{seen[k]}"

    print(f"\nplaced {len(cams)}; unplaced {len(unplaced)}", file=sys.stderr)
    for u in unplaced:
        print("  UNPLACED", u, file=sys.stderr)
    if not args.dry_run:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "w", encoding="utf-8") as fh:
            json.dump({"v": 1, "generated": time.strftime("%Y-%m-%d"), "cams": cams}, fh,
                      ensure_ascii=False, indent=1)
        print(f"wrote {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
