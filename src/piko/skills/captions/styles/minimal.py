"""Minimal style: clean Helvetica Neue, italic keywords, smooth fade."""

from __future__ import annotations

from pysubs2 import SSAStyle, Color

from .base import BaseStyle


class MinimalStyle(BaseStyle):

    ass_style_name = "Minimal"
    max_words = 6
    max_duration = 4.0
    fade = r"{\fad(200,200)}"

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "Minimal": SSAStyle(
                fontname="Helvetica Neue",
                fontsize=48,
                bold=False,
                primarycolor=Color(255, 255, 255, 0),
                outlinecolor=Color(0, 0, 0, 80),
                outline=1.5,
                shadow=0.0,
                alignment=2,
                marginv=40,
                spacing=1.0,
            ),
        }

    def decorate_word(self, w: dict) -> str:
        sem = self.semantic_tag(w)
        if w.get("is_keyword"):
            return f"{{{sem}\\i1}}{w['word']}{{\\i0}}{{\\r}}" if sem \
                else f"{{\\i1}}{w['word']}{{\\i0}}"
        if sem:
            return f"{{{sem}}}{w['word']}{{\\r}}"
        return w["word"]
