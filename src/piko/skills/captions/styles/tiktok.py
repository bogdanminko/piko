"""TikTok style: word-by-word highlighting, semi-transparent background."""

from __future__ import annotations

from pysubs2 import Alignment, Color, SSAEvent, SSAStyle

from ..fonts import pick_font
from .base import BaseStyle


class TikTokStyle(BaseStyle):
    max_words = 4

    font_scale = 0.0537
    margin_v_scale = 0.0741
    outline_scale = 0.0

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "TikTok": self.apply_geometry(
                SSAStyle(
                    fontname=pick_font("Futura", "Avenir Next", "Helvetica Neue"),
                    bold=True,
                    primarycolor=Color(255, 255, 255, 0),
                    secondarycolor=Color(255, 255, 0, 0),
                    outlinecolor=Color(0, 0, 0, 0),
                    backcolor=Color(0, 0, 0, 160),
                    borderstyle=3,  # opaque box
                    alignment=Alignment.BOTTOM_CENTER,
                )
            ),
        }

    def generate_events(self, words: list[dict]) -> list[SSAEvent]:
        """Word-by-word: current word bright white, others dimmed gray."""
        events = []
        for line_words in self.group_words(words):
            for i, w in enumerate(line_words):
                parts = []
                for j, lw in enumerate(line_words):
                    text = self.word_text(lw)
                    if j == i:
                        # Semantic color wins over the default white
                        tag = self.semantic_tag(lw) or "\\c&HFFFFFF&"
                        parts.append(f"{{{tag}\\b1}}{text}{{\\r}}")
                    else:
                        parts.append(f"{{\\c&H888888&}}{text}{{\\r}}")

                event = SSAEvent(
                    start=self.ms(w["start"]),
                    end=self.ms(w["end"]),
                    style="TikTok",
                    text="".join(parts),
                )
                events.append(event)
        return events
