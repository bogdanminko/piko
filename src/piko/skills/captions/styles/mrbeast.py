"""MrBeast style: Impact font, white + yellow keywords, thick outline."""

from __future__ import annotations

from pysubs2 import Alignment, Color, SSAStyle

from ..fonts import pick_font
from .base import BaseStyle


class MrBeastStyle(BaseStyle):
    ass_style_name = "MrBeast"
    max_words = 4
    fade = r"{\fad(100,100)}"

    # Fractions of frame height, equal to the pixel values this style used
    # to hardcode for 1080-tall video.
    font_scale = 0.0667
    margin_v_scale = 0.0556
    outline_scale = 0.0037
    shadow_scale = 0.0019
    keyword_ratio = 1.111

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "MrBeast": self.apply_geometry(
                SSAStyle(
                    fontname=pick_font("Impact", "Arial Black", "Helvetica"),
                    bold=True,
                    primarycolor=Color(255, 255, 255, 0),
                    outlinecolor=Color(0, 0, 0, 0),
                    backcolor=Color(0, 0, 0, 128),
                    alignment=Alignment.BOTTOM_CENTER,
                )
            ),
        }

    def decorate_word(self, w: dict) -> str:
        sem = self.semantic_tag(w)
        text = self.word_text(w)
        if w.get("is_keyword"):
            # Semantic color wins; otherwise yellow (BGR: 00FFFF)
            color = sem or "\\c&H00FFFF&"
            return f"{{{color}\\fs{self.keyword_font_size}}}{text}{{\\r}}"
        if sem:
            return f"{{{sem}}}{text}{{\\r}}"
        return text
