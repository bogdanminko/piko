"""Base class for subtitle styles."""

from __future__ import annotations

from abc import ABC, abstractmethod

from pysubs2 import SSAEvent, SSAStyle

DEFAULT_HIGHLIGHT = "#FFD700"  # yellow

# Word animation modes (apply to styles using the default event generator):
#   static    — whole line shown at once (classic)
#   reveal    — words appear one by one as they are spoken
#   highlight — whole line visible, the word being spoken is tinted
WORD_MODES = ("static", "reveal", "highlight")


class BaseStyle(ABC):
    """Abstract base for all subtitle styles.

    Subclasses either set the class attributes below and override
    decorate_word()/word_text() (line-based styles), or override
    generate_events() entirely (styles with built-in animation like
    karaoke and tiktok, which ignore word_mode).
    """

    # Defaults for the built-in event generator
    ass_style_name: str = ""
    max_words: int = 4
    max_duration: float = 3.0
    fade: str = ""

    def __init__(
        self,
        video_width: int = 1920,
        video_height: int = 1080,
        word_mode: str = "static",
        highlight_color: str | None = None,
    ) -> None:
        self.video_width = video_width
        self.video_height = video_height
        self.word_mode = word_mode if word_mode in WORD_MODES else "static"
        self.highlight_tag = self._hex_to_ass_color(
            highlight_color or DEFAULT_HIGHLIGHT
        )

    @staticmethod
    def _hex_to_ass_color(hex_color: str) -> str:
        """'#RRGGBB' -> ASS color override tag (BGR order)."""
        h = hex_color.lstrip("#")
        if len(h) != 6:
            h = "FFD700"
        r, g, b = h[0:2], h[2:4], h[4:6]
        return f"\\c&H00{b.upper()}{g.upper()}{r.upper()}&"

    @abstractmethod
    def get_styles(self) -> dict[str, SSAStyle]:
        """Return dict of style_name -> SSAStyle to register in the ASS file."""

    # --- Hooks for the default generator ---

    def word_text(self, w: dict) -> str:
        """Display text for a word (e.g. hormozi uppercases)."""
        return w["word"]

    def semantic_tag(self, w: dict) -> str:
        """ASS color tag for a semantically colored word, or ''."""
        hexc = w.get("semantic_color")
        return self._hex_to_ass_color(hexc) if hexc else ""

    def decorate_word(self, w: dict) -> str:
        """ASS-tagged text for one word, keyword styling included."""
        sem = self.semantic_tag(w)
        if sem:
            return f"{{{sem}}}{self.word_text(w)}{{\\r}}"
        return self.word_text(w)

    def _highlighted_word(self, w: dict) -> str:
        return f"{{{self.highlight_tag}\\b1}}{self.word_text(w)}{{\\r}}"

    # --- Event generation ---

    def generate_events(self, words: list[dict]) -> list[SSAEvent]:
        """Build events honoring word_mode. Styles with built-in word
        animation (karaoke, tiktok) override this and ignore word_mode."""
        events: list[SSAEvent] = []
        for line in self.group_words(words, self.max_words, self.max_duration):
            decorated = [self.decorate_word(w) for w in line]
            line_end = self.ms(line[-1]["end"])

            if self.word_mode in ("reveal", "highlight"):
                for i, w in enumerate(line):
                    start = self.ms(w["start"])
                    end = (self.ms(line[i + 1]["start"])
                           if i + 1 < len(line) else line_end)
                    if end <= start:
                        end = start + 10

                    if self.word_mode == "reveal":
                        text = "".join(decorated[: i + 1])
                    else:
                        parts = list(decorated)
                        parts[i] = self._highlighted_word(w)
                        text = "".join(parts)

                    events.append(SSAEvent(
                        start=start, end=end,
                        style=self.ass_style_name, text=text,
                    ))
            else:
                events.append(SSAEvent(
                    start=self.ms(line[0]["start"]), end=line_end,
                    style=self.ass_style_name,
                    text=self.fade + "".join(decorated),
                ))
        return events

    def group_words(
        self,
        words: list[dict],
        max_words: int = 5,
        max_duration: float = 3.0,
    ) -> list[list[dict]]:
        """Group words into lines of max_words or max_duration seconds."""
        lines: list[list[dict]] = []
        current: list[dict] = []

        for w in words:
            current.append(w)
            if len(current) >= max_words:
                lines.append(current)
                current = []
            elif current and (w["end"] - current[0]["start"]) > max_duration:
                lines.append(current)
                current = []

        if current:
            lines.append(current)

        return lines

    @staticmethod
    def ms(seconds: float) -> int:
        """Convert seconds to milliseconds for pysubs2."""
        return int(seconds * 1000)
