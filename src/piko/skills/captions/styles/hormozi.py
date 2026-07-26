"""Hormozi style: Montserrat Bold, ALL CAPS, cycling keyword colors."""

from __future__ import annotations

from pysubs2 import SSAStyle, Color

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

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._color_idx = 0

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "Hormozi": SSAStyle(
                fontname="Montserrat",
                fontsize=68,
                bold=True,
                primarycolor=Color(255, 255, 255, 0),
                outlinecolor=Color(0, 0, 0, 0),
                outline=3.0,
                shadow=0.0,
                alignment=2,
                marginv=50,
            ),
        }

    def word_text(self, w: dict) -> str:
        return w["word"].upper()

    def decorate_word(self, w: dict) -> str:
        text = self.word_text(w)
        sem = self.semantic_tag(w)
        if w.get("is_keyword"):
            if sem:
                return f"{{{sem}\\b1\\fs74}}{text}{{\\r}}"
            color = KEYWORD_COLORS[self._color_idx % len(KEYWORD_COLORS)]
            self._color_idx += 1
            return f"{{\\c{color}\\b1\\fs74}}{text}{{\\r}}"
        if sem:
            return f"{{{sem}}}{text}{{\\r}}"
        return text
