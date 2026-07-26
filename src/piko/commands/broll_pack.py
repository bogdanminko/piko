"""`download_broll_pack` / `fetch_broll` — openly licensed b-roll, no keys.

The starter pack is a hand-picked set of openly licensed clips (CC0 /
Public domain / CC BY, no share-alike) from Wikimedia Commons and
NASA. `fetch_broll` is the generic handle: search Wikimedia Commons for
any query, filter to the same open licenses, download the best hits into
a concept folder. Everything is normalized with ffmpeg (h264, no audio,
trimmed) and lands in the user's local library next to their own clips.
License and attribution go into ATTRIBUTION.txt per concept folder; CC BY
credits are the user's responsibility to show.
"""

from __future__ import annotations

import json
import re
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

from ..core.broll import BROLL_DIR, canonical_concept
from ..core.media import FFMPEG
from ..protocol import emit

USER_AGENT = "piko-broll-pack/0.1 (https://github.com/; local app)"

ALLOWED_HOSTS = ("https://upload.wikimedia.org/", "https://images-assets.nasa.gov/")
OK_LICENSES = ("CC0", "Public domain", "CC BY 2.0", "CC BY 3.0", "CC BY 4.0")
MAX_SOURCE_MB = 80

# One clip per entry. trim = (start_seconds, duration_seconds).
STARTER_PACK: list[dict] = [
    {
        "concept": "nature",
        "aliases": ["природ", "лес", "река", "гор", "nature", "river", "forest"],
        "slug": "crooked-river",
        "url": "https://upload.wikimedia.org/wikipedia/commons/f/f9/Crooked_River_%2836648924083%29.webm",
        "license": "Public domain (US BLM)",
        "credit": "Bureau of Land Management Oregon — 'Crooked River', Wikimedia Commons",
        "trim": (0, 8),
    },
    {
        "concept": "sea",
        "aliases": ["мор", "океан", "пляж", "волн", "sea", "ocean", "beach", "waves"],
        "slug": "iceland-coast",
        "url": "https://upload.wikimedia.org/wikipedia/commons/9/9b/Ocean_waves_at_L%C3%A6kjavik_beach%2C_Iceland.webm",
        "license": "CC BY 3.0",
        "credit": "Jakub Hałun — 'Ocean waves at Lækjavik beach, Iceland', Wikimedia Commons",
        "trim": (0, 8),
    },
    {
        "concept": "food",
        "aliases": ["ед", "пицц", "готов", "кухн", "food", "pizza", "cooking"],
        "slug": "baking-pizza",
        "url": "https://upload.wikimedia.org/wikipedia/commons/2/22/Bubbling_baking_pizza.webm",
        "license": "CC BY 2.0",
        "credit": "'Bubbling baking pizza', Wikimedia Commons",
        "trim": (0, 4.3),
    },
    {
        "concept": "city",
        "aliases": ["город", "здани", "небоскреб", "city", "skyline", "urban"],
        "slug": "shanghai-skyline",
        "url": "https://upload.wikimedia.org/wikipedia/commons/9/91/Shanghai_Bund%2C_Lujiazui_Skyline_Timelapse.webm",
        "license": "CC0",
        "credit": "'Shanghai Bund, Lujiazui Skyline Timelapse', Wikimedia Commons",
        "trim": (5, 8),
    },
    {
        "concept": "fire",
        "aliases": ["огон", "огн", "плам", "гор", "fire", "flame", "burning"],
        "slug": "table-fire",
        "url": "https://upload.wikimedia.org/wikipedia/commons/6/6d/Video_of_tabletop_fireplace_%28or_fire_pit%29_burning_with_removed_limiter_grid_-_don%27t_try_this_at_home%2C_just_for_demo.webm",
        "license": "CC BY 4.0",
        "credit": "'Video of tabletop fireplace burning', Wikimedia Commons",
        "trim": (0, 7),
    },
    {
        "concept": "computer",
        "aliases": [
            "компьютер",
            "клавиатур",
            "печата",
            "код",
            "ноутбук",
            "typing",
            "keyboard",
            "laptop",
            "computer",
        ],
        "slug": "typing-laptop",
        "url": "https://upload.wikimedia.org/wikipedia/commons/transcoded/d/d0/Hunt_and_peck_typing_%E2%80%94_Monkeytype_benchmark.webm/Hunt_and_peck_typing_%E2%80%94_Monkeytype_benchmark.webm.480p.vp9.webm",
        "license": "CC BY 4.0",
        "credit": "'Hunt and peck typing — Monkeytype benchmark', Wikimedia Commons",
        "trim": (2, 8),
    },
    {
        "concept": "dog",
        "aliases": ["собак", "щенок", "щенк", "пес", "dog", "puppy"],
        "slug": "puppies-playing",
        "url": "https://upload.wikimedia.org/wikipedia/commons/5/5a/Puppiesplaying-tokyoarea-jan7-2020.webm",
        "license": "CC BY 4.0",
        "credit": "'Puppies playing, Tokyo area', Wikimedia Commons",
        "trim": (4, 8),
    },
    {
        "concept": "rabbit",
        "aliases": ["зайк", "заяц", "зайц", "кролик", "ушк", "bunny", "rabbit"],
        "slug": "rabbit-closeup",
        "url": "https://upload.wikimedia.org/wikipedia/commons/4/4e/Rabbit_grinding_teeth.webm",
        "license": "CC0",
        "credit": "'Rabbit grinding teeth', Wikimedia Commons",
        "trim": (2, 8),
    },
    {
        "concept": "toys",
        "aliases": ["игрушк", "кубик", "конструктор", "toy", "blocks"],
        "slug": "balancing-blocks",
        "url": "https://upload.wikimedia.org/wikipedia/commons/b/bf/Balancing_Blocks_by_Fort_Standard.webm",
        "license": "CC BY 3.0",
        "credit": "Fort Standard — 'Balancing Blocks', Wikimedia Commons",
        "trim": (57, 8),
    },
    {
        "concept": "snow",
        "aliases": ["снег", "снеж", "зим", "snow", "winter"],
        "slug": "snow-forest",
        "url": "https://upload.wikimedia.org/wikipedia/commons/5/56/Snow_falling_in_Charlton_MA_2025-12-14.webm",
        "license": "CC0",
        "credit": "'Snow falling in Charlton MA', Wikimedia Commons",
        "trim": (2, 8),
    },
    {
        "concept": "rain",
        "aliases": ["дожд", "ливень", "ливн", "rain"],
        "slug": "rain-window",
        "url": "https://upload.wikimedia.org/wikipedia/commons/9/95/Raindrops_against_the_window_in_the_night_city%2C_Las_Palmas.webm",
        "license": "CC0",
        "credit": "'Raindrops against the window in the night city, Las Palmas', Wikimedia Commons",
        "trim": (2, 8),
    },
    {
        "concept": "train",
        "aliases": ["поезд", "электричк", "метро", "вокзал", "train", "railway"],
        "slug": "tokyo-train",
        "url": "https://upload.wikimedia.org/wikipedia/commons/4/47/Tokyo_-_Kawagoe_train_passing_by_platform.webm",
        "license": "CC0",
        "credit": "'Tokyo — Kawagoe train passing by platform', Wikimedia Commons",
        "trim": (3, 8),
    },
    {
        "concept": "airplane",
        "aliases": ["самолет", "аэропорт", "авиа", "airplane", "plane", "airport"],
        "slug": "takeoff-pdx",
        "url": "https://upload.wikimedia.org/wikipedia/commons/8/81/United_Airlines_N69826_737-900ER_Takeoff_Portland_Airport_%28PDX%29.webm",
        "license": "CC BY 3.0",
        "credit": "'United Airlines 737-900ER Takeoff Portland Airport', Wikimedia Commons",
        "trim": (28, 8),
    },
    {
        "concept": "waterfall",
        "aliases": ["водопад", "вода", "воды", "водой", "waterfall", "water"],
        "slug": "watagataki-falls",
        "url": "https://upload.wikimedia.org/wikipedia/commons/8/86/Watagataki_Falls_%28Video%29.webm",
        "license": "CC0",
        "credit": "'Watagataki Falls', Wikimedia Commons",
        "trim": (2, 8),
    },
    {
        "concept": "coffee",
        "aliases": ["кофе", "кофемашин", "чашк", "утро", "coffee"],
        "slug": "coffee-maker",
        "url": "https://upload.wikimedia.org/wikipedia/commons/3/3c/Moccamaster_coffee_maker.webm",
        "license": "CC BY 3.0",
        "credit": "'Moccamaster coffee maker', Wikimedia Commons",
        "trim": (8, 8),
    },
    {
        "concept": "rocket",
        "aliases": ["ракет", "космос", "запуск", "rocket", "space", "launch"],
        "slug": "nasa-launch",
        "url": "https://images-assets.nasa.gov/video/KSC-20240525-MH-RKL01-0001-Rocket_Lab_PREFIRE_1_Launch_1080p-M6988/KSC-20240525-MH-RKL01-0001-Rocket_Lab_PREFIRE_1_Launch_1080p-M6988~large.mp4",
        "license": "Public domain (NASA)",
        "credit": "NASA/Rocket Lab — 'PREFIRE-1 Launch', NASA Image and Video Library",
        "trim": (2, 8),
    },
    # Color concepts — pair with semantic_colors.py painting the word itself,
    # so "красный" or "red" gets both a colored highlight and matching
    # footage. Commons has thin coverage for plain single-color b-roll;
    # only clean, unambiguous matches are included here (no green/yellow/
    # white pick was good enough — add those manually if you find one).
    {
        "concept": "red",
        "aliases": ["red", "красн"],
        "slug": "red-flowers",
        "url": "https://upload.wikimedia.org/wikipedia/commons/7/70/Red_flowers.webm",
        "license": "CC BY 3.0",
        "credit": "'Red flowers', Wikimedia Commons",
        "trim": (0, 8),
    },
    {
        "concept": "orange",
        "aliases": ["orange", "оранжев"],
        "slug": "sunset-halfdome",
        "url": "https://upload.wikimedia.org/wikipedia/commons/4/4c/Sunset_on_Halfdome_timelapse_Yosemite_CA_2023-07-15_20-11-06_1.webm",
        "license": "CC BY 4.0",
        "credit": "'Sunset on Halfdome timelapse, Yosemite CA', Wikimedia Commons",
        "trim": (0, 8),
    },
    {
        "concept": "purple",
        "aliases": ["purple", "фиолетов"],
        "slug": "lavender-field",
        "url": "https://upload.wikimedia.org/wikipedia/commons/4/43/%D0%9B%D0%B0%D0%B2%D0%B0%D0%BD%D0%B4%D1%83%D0%BB%D0%B0.webm",
        "license": "CC BY 3.0",
        "credit": "'Лавандула' (lavender field), Wikimedia Commons",
        "trim": (0, 8),
    },
    {
        "concept": "pink",
        "aliases": ["pink", "розов"],
        "slug": "pink-flower-closeup",
        "url": "https://upload.wikimedia.org/wikipedia/commons/3/31/Pink_flower_close_up.webm",
        "license": "CC BY 3.0",
        "credit": "'Pink flower close up', Wikimedia Commons",
        "trim": (0, 6),
    },
    {
        "concept": "blue",
        "aliases": ["blue", "син"],
        "slug": "cloud-timelapse-new-mexico",
        "url": "https://upload.wikimedia.org/wikipedia/commons/1/14/Cloud_timelapse_in_New_Mexico.webm",
        "license": "CC BY 2.0",
        "credit": "'Cloud timelapse in New Mexico', Wikimedia Commons",
        "trim": (0, 8),
    },
]


def _normalize(src: Path, dst: Path, trim: tuple[float, float]) -> None:
    """Trim + transcode to a lean, audio-free h264 mp4 capped at 1280px."""
    import subprocess

    start, duration = trim
    cmd = [
        FFMPEG,
        "-ss",
        str(start),
        "-t",
        str(duration),
        "-i",
        str(src),
        "-an",
        "-vf",
        "scale='min(1280,iw)':-2",
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "23",
        "-y",
        str(dst),
    ]
    subprocess.run(cmd, capture_output=True, check=True)


def _download_and_normalize(url: str, target: Path, trim: tuple[float, float]) -> None:
    """Fetch one clip from an allowed host and normalize it into target."""
    if not url.startswith(ALLOWED_HOSTS):
        raise ValueError(f"unexpected clip URL: {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})  # noqa: S310
    with tempfile.NamedTemporaryFile(suffix=Path(urllib.parse.urlparse(url).path).suffix) as tmp:
        with urllib.request.urlopen(request, timeout=180) as response:  # noqa: S310
            while chunk := response.read(1 << 20):
                tmp.write(chunk)
        tmp.flush()
        _normalize(Path(tmp.name), target, trim)


def _record_attribution(folder: Path, filename: str, license_name: str, credit: str) -> None:
    attribution = folder / "ATTRIBUTION.txt"
    line = f"{filename} — {license_name} — {credit}\n"
    if not attribution.is_file() or line not in attribution.read_text(encoding="utf-8"):
        with attribution.open("a", encoding="utf-8") as fh:
            fh.write(line)


def commons_search(query: str, limit: int = 12) -> list[dict]:
    """Search Wikimedia Commons for openly licensed videos.

    Returns [{"title", "url", "license", "width", "size_mb"}], filtered to
    OK_LICENSES, ≥640px wide and ≤MAX_SOURCE_MB.
    """
    api = (
        "https://commons.wikimedia.org/w/api.php?action=query&format=json"
        "&generator=search&gsrsearch="
        + urllib.parse.quote(f"{query} filemime:video/webm")
        + f"&gsrnamespace=6&gsrlimit={limit}"
        "&prop=imageinfo&iiprop=url%7Csize%7Cextmetadata&iiurlwidth=320"
    )
    request = urllib.request.Request(api, headers={"User-Agent": USER_AGENT})  # noqa: S310
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        data = json.load(response)

    results = []
    for page in data.get("query", {}).get("pages", {}).values():
        info = page.get("imageinfo", [{}])[0]
        license_name = info.get("extmetadata", {}).get("LicenseShortName", {}).get("value", "")
        width = info.get("width", 0)
        size_mb = info.get("size", 0) / 1024 / 1024
        if not license_name.startswith(OK_LICENSES):
            continue
        if width < 640 or size_mb > MAX_SOURCE_MB or not info.get("url"):
            continue
        results.append(
            {
                "title": page.get("title", "").removeprefix("File:"),
                "url": info["url"],
                "license": license_name,
                "width": width,
                "size_mb": round(size_mb, 1),
                "thumb": info.get("thumburl"),
            }
        )
    # Smaller files first: faster downloads, usually short single-scene clips.
    results.sort(key=lambda r: r["size_mb"])
    return results


def _slugify(title: str) -> str:
    slug = re.sub(r"[^\w]+", "-", title.rsplit(".", 1)[0], flags=re.UNICODE)
    return slug.strip("-").lower()[:60] or "clip"


def handle_search_broll(params: dict) -> None:
    """Search Commons and return openly licensed candidates for the UI."""
    query = params.get("query", "").strip()
    if not query:
        emit({"type": "error", "message": "search_broll needs a query", "code": "BAD_PARAMS"})
        return
    try:
        results = commons_search(query)
        emit(
            {
                "type": "result",
                "success": True,
                "clips": results[:10],
                "message": f"{len(results)} openly licensed clip(s) for '{query}'",
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_fetch_broll(params: dict) -> None:
    """Download one chosen clip (`url`) — or top hits for `query` — into
    the `concept` folder, recording its license in ATTRIBUTION.txt."""
    query = params.get("query", "").strip()
    url = params.get("url", "").strip()
    # Whatever language the user typed the keyword in, fold it onto the
    # canonical English folder ("лошадь"/"cheval" both land in "horse")
    # so the library doesn't fork into per-language duplicate folders.
    concept = canonical_concept(params.get("concept", "").strip() or query)
    max_clips = int(params.get("max_clips", 2))
    if not query and not url:
        emit({"type": "error", "message": "fetch_broll needs a query or url", "code": "BAD_PARAMS"})
        return
    if not concept:
        emit({"type": "error", "message": "fetch_broll needs a concept", "code": "BAD_PARAMS"})
        return

    try:
        # Direct mode: the user picked a specific search result.
        if url:
            title = params.get("title", "clip")
            license_name = params.get("license", "see source")
            folder = BROLL_DIR / concept
            folder.mkdir(parents=True, exist_ok=True)
            target = folder / f"{_slugify(title)}.mp4"
            if target.exists():
                emit(
                    {
                        "type": "result",
                        "success": True,
                        "message": f"'{title[:40]}' is already in '{concept}'",
                    }
                )
                return
            emit(
                {
                    "type": "progress",
                    "stage": "broll_fetch",
                    "percent": 20,
                    "message": f"Downloading {title[:50]}...",
                }
            )
            _download_and_normalize(url, target, (0, 8))
            _record_attribution(folder, target.name, license_name, f"'{title}', Wikimedia Commons")
            emit(
                {
                    "type": "result",
                    "success": True,
                    "message": f"Added '{title[:40]}' to '{concept}'",
                }
            )
            return
        emit(
            {
                "type": "progress",
                "stage": "broll_fetch",
                "percent": 5,
                "message": f"Searching Wikimedia Commons for '{query}'...",
            }
        )
        candidates = commons_search(query)
        if not candidates:
            emit(
                {
                    "type": "result",
                    "success": True,
                    "message": f"No openly licensed clips found for '{query}'",
                }
            )
            return

        folder = BROLL_DIR / concept
        folder.mkdir(parents=True, exist_ok=True)
        added = 0
        for candidate in candidates[:max_clips]:
            target = folder / f"{_slugify(candidate['title'])}.mp4"
            if target.exists():
                continue
            emit(
                {
                    "type": "progress",
                    "stage": "broll_fetch",
                    "percent": 20 + added * 35,
                    "message": f"Downloading {candidate['title'][:50]}...",
                }
            )
            _download_and_normalize(candidate["url"], target, (0, 8))
            _record_attribution(
                folder,
                target.name,
                candidate["license"],
                f"'{candidate['title']}', Wikimedia Commons",
            )
            added += 1

        emit(
            {
                "type": "result",
                "success": True,
                "message": f"Added {added} clip(s) to '{concept}'",
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_download_broll_pack(params: dict) -> None:
    """Download every missing starter-pack clip into the b-roll library."""
    downloaded = 0
    skipped = 0
    total = len(STARTER_PACK)
    try:
        for index, entry in enumerate(STARTER_PACK):
            folder = BROLL_DIR / entry["concept"]
            target = folder / f"{entry['slug']}.mp4"
            if target.exists():
                skipped += 1
                continue

            emit(
                {
                    "type": "progress",
                    "stage": "broll_pack",
                    "percent": round(index / total * 100, 1),
                    "message": f"Downloading {entry['slug']} ({index + 1}/{total})...",
                }
            )
            folder.mkdir(parents=True, exist_ok=True)

            _download_and_normalize(entry["url"], target, entry["trim"])

            # Merge aliases (keep any the user added) and record attribution.
            aliases_path = folder / "aliases.txt"
            existing = set()
            if aliases_path.is_file():
                existing = set(aliases_path.read_text(encoding="utf-8").split())
            aliases_path.write_text(
                "\n".join(sorted(existing | set(entry["aliases"]))) + "\n",
                encoding="utf-8",
            )
            _record_attribution(folder, f"{entry['slug']}.mp4", entry["license"], entry["credit"])
            downloaded += 1

        emit(
            {
                "type": "result",
                "success": True,
                "message": (
                    f"Starter pack ready: {downloaded} downloaded, {skipped} already present"
                ),
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
