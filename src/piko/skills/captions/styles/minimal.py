"""Minimal style: clean Helvetica Neue, italic keywords, smooth fade."""

from __future__ import annotations

from pysubs2 import Alignment, Color, SSAStyle

from ..fonts import pick_font
from .base import BaseStyle


class MinimalStyle(BaseStyle):
    ass_style_name = "Minimal"
    max_words = 6
    max_duration = 4.0
    fade = r"{\fad(200,200)}"

    font_scale = 0.0444
    margin_v_scale = 0.037
    outline_scale = 0.0014

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "Minimal": self.apply_geometry(
                SSAStyle(
                    fontname=pick_font("Helvetica Neue", "Helvetica"),
                    bold=False,
                    primarycolor=Color(255, 255, 255, 0),
                    outlinecolor=Color(0, 0, 0, 80),
                    alignment=Alignment.BOTTOM_CENTER,
                    spacing=1.0,
                )
            ),
        }

    def decorate_word(self, w: dict) -> str:
        sem = self.semantic_tag(w)
        text = self.word_text(w)
        if w.get("is_keyword"):
            return f"{{{sem}\\i1}}{text}{{\\i0}}{{\\r}}" if sem else f"{{\\i1}}{text}{{\\i0}}"
        if sem:
            return f"{{{sem}}}{text}{{\\r}}"
        return text
