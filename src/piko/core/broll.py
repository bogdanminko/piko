"""Local b-roll library — keyword-indexed folders of clips, no network.

The library is a user-managed directory:

    ~/Library/Application Support/Piko/BRoll/<concept>/*.mp4|mov|m4v|webm
    <concept>/aliases.txt   # optional extra keywords, one per line

Folder names are canonical English concepts ("dog", "fire", "green");
CONCEPT_LEXICON below maps transcript words in EN/RU/DE/FR onto them, so
an English folder still fires on "собака" or "Hund". aliases.txt adds
user keywords on top. Transcript words are matched by stem prefix, so
"кубик" catches "кубиками". Clips inside a concept rotate between renders
(state in the cache dir), so the same keyword doesn't always produce the
same insert.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from ..cache import CACHE_DIR

BROLL_DIR = Path.home() / "Library" / "Application Support" / "Piko" / "BRoll"
STATE_PATH = CACHE_DIR / "broll_state.json"

VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm"}

# Built-in multilingual keywords per canonical (English) folder name.
# Values are stems — _matches() prefix-matches inflected forms. Words
# shorter than 4 chars only match exactly, so short roots list a few
# inflections explicitly. Ambiguous cross-language words (EN "chat" vs
# FR chat, EN "rot" vs DE rot) are deliberately left out.
CONCEPT_LEXICON: dict[str, list[str]] = {
    "nature": [
        "nature",
        "forest",
        "river",
        "natur",
        "wald",
        "foret",
        "riviere",
        "природ",
        "лес",
        "леса",
        "лесу",
        "река",
        "реки",
    ],
    "sea": [
        "sea",
        "ocean",
        "beach",
        "waves",
        "meer",
        "ozean",
        "strand",
        "welle",
        "mer",
        "plage",
        "vague",
        "море",
        "моря",
        "океан",
        "пляж",
        "волн",
    ],
    "food": [
        "food",
        "pizza",
        "cooking",
        "kitchen",
        "essen",
        "kochen",
        "cuisine",
        "nourriture",
        "еда",
        "еды",
        "еду",
        "едой",
        "пицц",
        "готов",
        "кухн",
    ],
    "city": [
        "city",
        "skyline",
        "urban",
        "building",
        "stadt",
        "gebaude",
        "ville",
        "batiment",
        "город",
        "города",
        "здани",
        "небоскреб",
    ],
    "fire": [
        "fire",
        "flame",
        "burning",
        "feuer",
        "flamme",
        "feu",
        "огонь",
        "огня",
        "огне",
        "плам",
        "горит",
        "гореть",
    ],
    "computer": [
        "computer",
        "laptop",
        "keyboard",
        "typing",
        "rechner",
        "tastatur",
        "ordinateur",
        "clavier",
        "компьютер",
        "ноутбук",
        "клавиатур",
        "печата",
        "код",
        "кода",
    ],
    "dog": [
        "dog",
        "puppy",
        "hund",
        "welpe",
        "chien",
        "chiot",
        "собак",
        "щенок",
        "щенк",
        "пес",
        "пса",
    ],
    "rabbit": [
        "rabbit",
        "bunny",
        "hare",
        "kaninchen",
        "hase",
        "lapin",
        "зайк",
        "заяц",
        "зайц",
        "кролик",
    ],
    "cat": ["cat", "kitten", "katze", "chaton", "кот", "кота", "коте", "котят", "кошк"],
    "horse": ["horse", "pferd", "cheval", "лошад", "конь", "коня", "пони"],
    "toys": [
        "toy",
        "toys",
        "blocks",
        "lego",
        "spielzeug",
        "jouet",
        "игрушк",
        "кубик",
        "конструктор",
    ],
    "snow": [
        "snow",
        "winter",
        "schnee",
        "neige",
        "hiver",
        "снег",
        "снега",
        "снегу",
        "снеж",
        "зима",
        "зимы",
        "зимой",
        "зимн",
    ],
    "rain": ["rain", "regen", "pluie", "дожд", "ливень", "ливн"],
    "train": [
        "train",
        "railway",
        "metro",
        "subway",
        "zug",
        "bahn",
        "поезд",
        "электричк",
        "метро",
        "вокзал",
    ],
    "airplane": [
        "airplane",
        "aircraft",
        "airport",
        "flugzeug",
        "avion",
        "aeroport",
        "самолет",
        "авиа",
        "аэропорт",
    ],
    "waterfall": [
        "waterfall",
        "water",
        "wasserfall",
        "cascade",
        "chute",
        "водопад",
        "вода",
        "воды",
        "водой",
    ],
    "coffee": [
        "coffee",
        "espresso",
        "latte",
        "kaffee",
        "cafe",
        "кофе",
        "кофейн",
        "чашк",
        "эспрессо",
    ],
    "rocket": [
        "rocket",
        "space",
        "launch",
        "rakete",
        "weltraum",
        "espace",
        "ракет",
        "космос",
        "запуск",
    ],
    # Colors — semantic_colors paints the word, a matching folder cuts in
    # matching footage (green forest, blue ocean, red lava, ...).
    "green": ["green", "grun", "grune", "vert", "verte", "зелен"],
    "blue": [
        "blue",
        "blau",
        "blaue",
        "bleu",
        "bleue",
        "синий",
        "синие",
        "синего",
        "синяя",
        "голуб",
    ],
    "red": ["red", "rouge", "rote", "красн"],
    "yellow": ["yellow", "gelb", "gelbe", "jaune", "желт"],
    "orange": ["orange", "оранжев", "апельсин"],
    "purple": ["purple", "violet", "lila", "фиолетов", "сиренев"],
    "pink": ["pink", "rosa", "rose", "розов"],
    "white": ["white", "weiss", "blanc", "blanche", "белый", "белая", "белое", "белые"],
    "black": ["black", "schwarz", "noir", "noire", "черн"],
}

# Folders created by earlier Piko versions used Russian names — renamed
# once on scan so the on-disk library matches the English lexicon keys.
LEGACY_FOLDER_NAMES: dict[str, str] = {
    "природа": "nature",
    "море": "sea",
    "еда": "food",
    "город": "city",
    "огонь": "fire",
    "компьютер": "computer",
    "собака": "dog",
    "зайка": "rabbit",
    "кот": "cat",
    "лошадь": "horse",
    "игрушки": "toys",
    "кубики": "toys",
    "снег": "snow",
    "дождь": "rain",
    "поезд": "train",
    "самолет": "airplane",
    "водопад": "waterfall",
    "кофе": "coffee",
    "ракета": "rocket",
}

# Insert pacing defaults: short cuts, never back to back, let the original
# footage hook the viewer first.
CLIP_SECONDS = 2.2
MIN_GAP_SECONDS = 4.0
START_AFTER_SECONDS = 1.5
MAX_INSERTS = 6

_WORD_RE = re.compile(r"[^\w]+", re.UNICODE)

# Latin accents only — French "forêt"/German "grün" fold onto their
# unaccented lexicon stems. Deliberately NOT a blanket Unicode NFKD strip:
# that also decomposes Cyrillic й (= и + breve) and silently mangles it to
# "и", breaking every RU keyword and folder name that contains it.
_ACCENT_MAP = str.maketrans(
    {
        "é": "e",
        "è": "e",
        "ê": "e",
        "ë": "e",
        "à": "a",
        "â": "a",
        "ä": "a",
        "ô": "o",
        "ö": "o",
        "ù": "u",
        "û": "u",
        "ü": "u",
        "î": "i",
        "ï": "i",
        "ç": "c",
        "ÿ": "y",
    }
)


def _norm(word: str) -> str:
    """Lowercase, strip punctuation, fold ё→е and Latin accents away."""
    word = _WORD_RE.sub("", word).lower().replace("ё", "е").replace("ß", "ss")
    return word.translate(_ACCENT_MAP)


def _matches(word: str, keyword: str) -> bool:
    """Stem-ish match: the keyword minus its (often inflected) last letter
    as a prefix — "кубик" catches "кубиками", "деньги" catches "деньгами".
    Short keywords stay exact; irregular forms belong in aliases.txt."""
    if len(keyword) < 4:
        return word == keyword
    stem = keyword[:-1] if len(keyword) >= 5 else keyword
    return word == keyword or word.startswith(stem)


def canonical_concept(text: str) -> str:
    """Map free text in any supported language to the canonical (English)
    concept name it belongs to, e.g. "лошадь"/"cheval"/"Pferd" → "horse".
    Falls back to a normalized slug of the input so custom, non-built-in
    concepts still get a stable folder name."""
    norm = _norm(text)
    if not norm:
        return norm
    for concept, keywords in CONCEPT_LEXICON.items():
        if any(_matches(norm, kw) for kw in keywords):
            return concept
    return norm


@dataclass
class Concept:
    name: str
    keywords: list[str]
    clips: list[Path]


class BRollLibrary:
    def __init__(self, root: Path = BROLL_DIR, state_path: Path = STATE_PATH) -> None:
        self.root = root
        self.state_path = state_path
        self._concepts = self._scan()

    def _scan(self) -> list[Concept]:
        if not self.root.is_dir():
            return []
        self._migrate_legacy_folders()
        concepts = []
        for folder in sorted(self.root.iterdir()):
            if not folder.is_dir() or folder.name.startswith("."):
                continue
            clips = sorted(p for p in folder.iterdir() if p.suffix.lower() in VIDEO_EXTS)
            if not clips:
                continue
            canonical = _norm(folder.name)
            # Built-in concepts get their full EN/RU/DE/FR lexicon; custom
            # user folders fall back to matching their own name literally.
            keywords = list(CONCEPT_LEXICON.get(canonical, []))
            if not keywords:
                keywords = [_norm(w) for w in re.split(r"[-_\s]+", folder.name) if _norm(w)]
            aliases = folder / "aliases.txt"
            if aliases.is_file():
                keywords += [
                    _norm(line)
                    for line in aliases.read_text(encoding="utf-8").splitlines()
                    if _norm(line)
                ]
            concepts.append(Concept(folder.name, keywords, clips))
        return concepts

    def _migrate_legacy_folders(self) -> None:
        """One-time rename from an earlier version's Russian folder names
        to their canonical English concept, merging into an existing
        folder of that name if the user already has one (e.g. from a
        fresh fetch). Runs as its own pass over a fixed directory listing
        so a rename never shifts what the main scan loop sees."""
        for folder in sorted(self.root.iterdir()):
            if not folder.is_dir() or folder.name.startswith("."):
                continue
            target_name = LEGACY_FOLDER_NAMES.get(_norm(folder.name))
            if not target_name or target_name == folder.name:
                continue
            target = self.root / target_name
            if not target.exists():
                folder.rename(target)
                continue
            for item in folder.iterdir():
                dest = target / item.name
                if not dest.exists():
                    item.rename(dest)
            try:
                folder.rmdir()
            except OSError:
                pass

    @property
    def concepts(self) -> list[Concept]:
        return self._concepts

    def match_word(self, word: str) -> Concept | None:
        norm = _norm(word)
        if not norm:
            return None
        for concept in self._concepts:
            if any(_matches(norm, kw) for kw in concept.keywords):
                return concept
        return None

    def next_clip(self, concept: Concept) -> Path:
        """Round-robin over the concept's clips, persisted across renders."""
        state: dict[str, int] = {}
        if self.state_path.is_file():
            try:
                state = json.loads(self.state_path.read_text())
            except (json.JSONDecodeError, OSError):
                state = {}
        index = state.get(concept.name, 0) % len(concept.clips)
        state[concept.name] = index + 1
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(state))
        return concept.clips[index]


def compose_broll(
    video_path: str,
    inserts: list[dict],
    output_path: str | Path,
    progress_callback=None,
) -> None:
    """Overlay the planned clips onto the source video (audio untouched).

    Each clip is trimmed to its window, scaled to cover the frame and
    cropped — the result is a full-frame cut-in, ready for subtitle burn.
    """
    from .media import FFMPEG, audio_encoder_args, probe_video, run_ffmpeg, video_encoder_args

    info = probe_video(video_path)
    width, height = info.width, info.height
    inputs = ["-i", str(video_path)]
    for insert in inserts:
        inputs += ["-i", insert["clip"]]

    chains = []
    label = "0:v"
    for i, insert in enumerate(inserts):
        start = insert["start"]
        end = start + insert["duration"]
        prepared = f"b{i}"
        chains.append(
            f"[{i + 1}:v]trim=0:{insert['duration']:.3f},"
            f"scale={width}:{height}:force_original_aspect_ratio=increase,"
            f"crop={width}:{height},setpts=PTS-STARTPTS+{start:.3f}/TB[{prepared}]"
        )
        nxt = f"v{i}" if i < len(inserts) - 1 else "out"
        chains.append(
            f"[{label}][{prepared}]overlay=eof_action=pass"
            f":enable='between(t,{start:.3f},{end:.3f})'[{nxt}]"
        )
        label = nxt

    cmd = [
        FFMPEG,
        "-nostdin",
        *inputs,
        "-filter_complex",
        ";".join(chains),
        "-map",
        "[out]",
        "-map",
        "0:a?",
        *audio_encoder_args(info.audio_codec),
        *video_encoder_args(width, height),
        "-pix_fmt",
        "yuv420p",
        "-y",
        str(output_path),
    ]

    # This is an intermediate the burn reads back, so no faststart here —
    # but stderr still has to be drained, which run_ffmpeg does whether or
    # not a progress callback was given.
    run_ffmpeg(cmd, progress_callback)


def plan_inserts(
    segments: list[dict],
    library: BRollLibrary,
    *,
    clip_seconds: float = CLIP_SECONDS,
    min_gap: float = MIN_GAP_SECONDS,
    start_after: float = START_AFTER_SECONDS,
    max_inserts: int = MAX_INSERTS,
) -> list[dict]:
    """Match transcript words against the library and schedule inserts.

    Returns [{"start", "duration", "clip", "concept"}, ...] sorted by start.
    """
    if not library.concepts:
        return []
    inserts: list[dict] = []
    last_end = -1e9
    for segment in segments:
        for word in segment.get("words", []):
            start = float(word.get("start", 0.0))
            if start < start_after or start < last_end + min_gap:
                continue
            concept = library.match_word(str(word.get("word", "")))
            if concept is None:
                continue
            clip = library.next_clip(concept)
            inserts.append(
                {
                    "start": round(start, 3),
                    "duration": clip_seconds,
                    "clip": str(clip),
                    "concept": concept.name,
                }
            )
            last_end = start + clip_seconds
            if len(inserts) >= max_inserts:
                return inserts
    return inserts
