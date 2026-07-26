"""Karaoke style: progressive color fill using ASS \\kf tags."""

from __future__ import annotations

from pysubs2 import SSAEvent, SSAStyle, Color

from .base import BaseStyle


class KaraokeStyle(BaseStyle):

    def get_styles(self) -> dict[str, SSAStyle]:
        return {
            "Karaoke": SSAStyle(
                fontname="Arial",
                fontsize=62,
                bold=True,
                primarycolor=Color(0, 255, 255, 0),        # Yellow (highlighted)
                secondarycolor=Color(180, 180, 180, 0),    # Gray (pre-highlight)
                outlinecolor=Color(0, 0, 0, 0),
                outline=2.5,
                shadow=1.0,
                alignment=2,
                marginv=50,
            ),
        }

    def generate_events(self, words: list[dict]) -> list[SSAEvent]:
        """One line = one event with \\kf tags for progressive fill."""
        events = []
        for line_words in self.group_words(words, max_words=5):
            parts = []
            for w in line_words:
                duration_cs = int((w["end"] - w["start"]) * 100)  # centiseconds
                text = w["word"]
                sem = self.semantic_tag(w)

                if sem or w.get("is_keyword"):
                    color = sem or "\\c&H00FF00&"
                    parts.append(
                        f"{{\\kf{duration_cs}{color}}}{text}{{\\r}}"
                    )
                else:
                    parts.append(f"{{\\kf{duration_cs}}}{text}")

            event = SSAEvent(
                start=self.ms(line_words[0]["start"]),
                end=self.ms(line_words[-1]["end"]),
                style="Karaoke",
                text="".join(parts),
            )
            events.append(event)
        return events
