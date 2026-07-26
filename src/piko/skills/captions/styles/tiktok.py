"""TikTok style: word-by-word highlighting, semi-transparent background."""

from __future__ import annotations

from pysubs2 import SSAEvent, SSAStyle, Color

from .base import BaseStyle


class TikTokStyle(BaseStyle):

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "TikTok": SSAStyle(
                fontname="Futura",
                fontsize=58,
                bold=True,
                primarycolor=Color(255, 255, 255, 0),
                secondarycolor=Color(255, 255, 0, 0),
                outlinecolor=Color(0, 0, 0, 0),
                backcolor=Color(0, 0, 0, 160),
                borderstyle=3,  # opaque box
                outline=0.0,
                shadow=0.0,
                alignment=2,
                marginv=80,
            ),
        }

    def generate_events(self, words: list[dict]) -> list[SSAEvent]:
        """Word-by-word: current word bright white, others dimmed gray."""
        events = []
        for line_words in self.group_words(words, max_words=4):
            for i, w in enumerate(line_words):
                parts = []
                for j, lw in enumerate(line_words):
                    text = lw["word"]
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
