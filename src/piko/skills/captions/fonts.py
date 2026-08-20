"""Which typefaces this Mac actually has.

A style whose font is missing does not fail loudly — libass substitutes its
own default, which is the worst possible outcome for a style whose entire
identity is the typeface. Hormozi asks for Montserrat, which ships with
neither macOS nor this repository, so on a clean machine it silently stopped
being Hormozi. Resolving the name up front turns that into a deliberate
fallback.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

FONT_DIRS = (
    Path.home() / "Library" / "Fonts",
    Path("/Library/Fonts"),
    Path("/System/Library/Fonts"),
    Path("/System/Library/Fonts/Supplemental"),
)

FONT_SUFFIXES = frozenset({".ttf", ".otf", ".ttc", ".dfont"})


def _normalize(name: str) -> str:
    return name.lower().replace(" ", "").replace("-", "").replace("_", "")


@lru_cache(maxsize=1)
def installed_fonts() -> frozenset[str]:
    """Normalized file stems of every font installed on this machine."""
    names: set[str] = set()
    for directory in FONT_DIRS:
        try:
            entries = list(directory.iterdir())
        except OSError:
            continue
        names.update(
            _normalize(entry.stem) for entry in entries if entry.suffix.lower() in FONT_SUFFIXES
        )
    return frozenset(names)


def is_available(font_name: str) -> bool:
    """Whether a font family looks installed (family name, not file name)."""
    key = _normalize(font_name)
    return any(stem.startswith(key) for stem in installed_fonts())


def pick_font(*candidates: str) -> str:
    """The first installed candidate; the last one as a deliberate default.

    Order them preferred-first and end with something macOS always has, so
    the fallback is a choice this code made rather than one libass made.
    """
    for name in candidates:
        if is_available(name):
            return name
    return candidates[-1]
