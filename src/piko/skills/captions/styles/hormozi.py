"""Hormozi style: Montserrat Bold, ALL CAPS, cycling keyword colors."""

from __future__ import annotations

from pysubs2 import Alignment, Color, SSAStyle

from ..fonts import pick_font
from .base import BaseStyle

# BGR format colors for ASS
KEYWORD_COLORS = [
    "&H0000FF&",  # Red
    "&H00FFFF&",  # Yellow
    "&H00FF00&",  # Green
    "&H00A5FF&",  # Orange
]


class HormoziStyle(BaseStyle):
    ass_style_name = "Hormozi"
    max_words = 4
    fade = r"{\fad(80,80)}"

    font_scale = 0.063
    margin_v_scale = 0.0463
    outline_scale = 0.0028
    keyword_ratio = 1.088

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._color_idx = 0

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "Hormozi": self.apply_geometry(
                SSAStyle(
                    # Montserrat ships with neither macOS nor this repo, so the
                    # fallback has to be named here rather than left to libass.
                    fontname=pick_font("Montserrat", "Avenir Next", "Helvetica Neue"),
                    bold=True,
                    primarycolor=Color(255, 255, 255, 0),
                    outlinecolor=Color(0, 0, 0, 0),
                    alignment=Alignment.BOTTOM_CENTER,
                )
            ),
        }

    def word_text(self, w: dict) -> str:
        return super().word_text(w).upper()

    def decorate_word(self, w: dict) -> str:
        text = self.word_text(w)
        sem = self.semantic_tag(w)
        size = self.keyword_font_size
        if w.get("is_keyword"):
            if sem:
                return f"{{{sem}\\b1\\fs{size}}}{text}{{\\r}}"
            color = KEYWORD_COLORS[self._color_idx % len(KEYWORD_COLORS)]
            self._color_idx += 1
            return f"{{\\c{color}\\b1\\fs{size}}}{text}{{\\r}}"
        if sem:
            return f"{{{sem}}}{text}{{\\r}}"
        return text
