"""MrBeast style: Impact font, white + yellow keywords, thick outline."""

from __future__ import annotations

from pysubs2 import SSAStyle, Color

from .base import BaseStyle


class MrBeastStyle(BaseStyle):

    ass_style_name = "MrBeast"
    max_words = 4
    fade = r"{\fad(100,100)}"

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "MrBeast": SSAStyle(
                fontname="Impact",
                fontsize=72,
                bold=True,
                primarycolor=Color(255, 255, 255, 0),
                outlinecolor=Color(0, 0, 0, 0),
                backcolor=Color(0, 0, 0, 128),
                outline=4.0,
                shadow=2.0,
                alignment=2,  # bottom center
                marginv=60,
            ),
        }

    def decorate_word(self, w: dict) -> str:
        sem = self.semantic_tag(w)
        if w.get("is_keyword"):
            # Semantic color wins; otherwise yellow (BGR: 00FFFF)
            color = sem or "\\c&H00FFFF&"
            return f"{{{color}\\fs80}}{w['word']}{{\\r}}"
        if sem:
            return f"{{{sem}}}{w['word']}{{\\r}}"
        return w["word"]
