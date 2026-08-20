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

# Left/right safe area, as a fraction of frame width. libass would
# otherwise wrap against pysubs2's 10 px default and run to the edge.
SIDE_SAFE_AREA = 0.05

# Taller-than-wide frames get lifted clear of the platform UI: on 9:16 the
# bottom eighth is where TikTok, Reels and Shorts draw their own controls,
# and a style's own bottom margin lands right underneath them.
PORTRAIT_SAFE_BOTTOM = 0.12

# A silence this long ends the caption card rather than being spanned by it.
PAUSE_BREAK_SECONDS = 0.35

# Rough advance width of one character in units of the font size, and how
# many lines a card may wrap to. Together they bound a card by how much
# room it actually has, which a word count cannot do.
AVG_CHAR_WIDTH_RATIO = 0.5
MAX_WRAPPED_LINES = 2

SENTENCE_ENDINGS = ".!?…。！？"
_TRAILING_MARKS = "\"'»)]}”’"

MIN_FONT_SIZE = 16


def escape_ass(text: str) -> str:
    """Neutralise braces so transcript text cannot open an override block."""
    return text.replace("{", "\\{").replace("}", "\\}")


def ends_sentence(word: str) -> bool:
    text = word.rstrip().rstrip(_TRAILING_MARKS)
    return bool(text) and text[-1] in SENTENCE_ENDINGS


def group_words_into_cards(
    words: list[dict],
    *,
    max_words: int,
    max_duration: float,
    max_chars: int,
    pause_break: float = PAUSE_BREAK_SECONDS,
) -> list[list[dict]]:
    """Group timed words into caption cards.

    A card ends at a sentence, at a pause, or when it runs out of words,
    seconds or room — whichever comes first. Sentences and pauses are what
    make the result readable; the counts are only the backstop.

    Every limit is checked *before* the word is appended. Checking after is
    what used to let a card swallow the word on the far side of a silence
    and then hang on screen for the length of that silence.

    Shared by the burned-in styles and the plain .srt/.vtt export, so the
    file handed to YouTube breaks in the same places as the picture.
    """
    cards: list[list[dict]] = []
    current: list[dict] = []

    for w in words:
        if current:
            chars = sum(len(x["word"]) for x in current) + len(w["word"])
            if (
                len(current) >= max_words
                or w["start"] - current[-1]["end"] >= pause_break
                or w["end"] - current[0]["start"] > max_duration
                or chars > max_chars
            ):
                cards.append(current)
                current = []
        current.append(w)
        if ends_sentence(w["word"]):
            cards.append(current)
            current = []

    if current:
        cards.append(current)

    return cards


class BaseStyle(ABC):
    """Abstract base for all subtitle styles.

    Subclasses either set the class attributes below and override
    decorate_word()/word_text() (line-based styles), or override
    generate_events() entirely (styles with built-in animation like
    karaoke and tiktok, which ignore word_mode).

    Typography is declared as fractions of the frame rather than pixels, so
    one style looks the same on a 1080p landscape clip, a 9:16 phone
    recording and a 4K master. The fractions below reproduce the pixel
    values the styles used to hardcode for 1080-tall video.
    """

    # Defaults for the built-in event generator
    ass_style_name: str = ""
    max_words: int = 4
    max_duration: float = 3.0
    fade: str = ""

    # Geometry, as fractions of frame height (width for the side margin)
    font_scale: float = 0.0667
    margin_v_scale: float = 0.0556
    outline_scale: float = 0.0037
    shadow_scale: float = 0.0
    keyword_ratio: float = 1.0

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
        self.highlight_tag = self._hex_to_ass_color(highlight_color or DEFAULT_HIGHLIGHT)

    # --- Geometry ---

    @property
    def font_size(self) -> int:
        return max(int(round(self.video_height * self.font_scale)), MIN_FONT_SIZE)

    @property
    def keyword_font_size(self) -> int:
        return max(int(round(self.font_size * self.keyword_ratio)), MIN_FONT_SIZE)

    @property
    def margin_h(self) -> int:
        return int(round(self.video_width * SIDE_SAFE_AREA))

    @property
    def margin_v(self) -> int:
        fraction = self.margin_v_scale
        if self.video_height > self.video_width:
            fraction = max(fraction, PORTRAIT_SAFE_BOTTOM)
        return int(round(self.video_height * fraction))

    @property
    def outline(self) -> float:
        return round(self.video_height * self.outline_scale, 2)

    @property
    def shadow(self) -> float:
        return round(self.video_height * self.shadow_scale, 2)

    @property
    def max_chars(self) -> int:
        """How many characters fit in a card at this size, wrapping allowed."""
        usable = max(self.video_width - 2 * self.margin_h, 1)
        per_line = usable / max(self.font_size * AVG_CHAR_WIDTH_RATIO, 1.0)
        return max(int(per_line * MAX_WRAPPED_LINES), 8)

    def apply_geometry(self, style: SSAStyle) -> SSAStyle:
        """Fill in every size and position resolved from the frame.

        Styles declare colours, weight and typeface; the numbers that depend
        on how big the picture is are filled in here, once, for all of them.
        """
        style.fontsize = self.font_size
        style.outline = self.outline
        style.shadow = self.shadow
        style.marginv = self.margin_v
        style.marginl = self.margin_h
        style.marginr = self.margin_h
        return style

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
        return escape_ass(w["word"])

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
                    end = self.ms(line[i + 1]["start"]) if i + 1 < len(line) else line_end
                    if end <= start:
                        end = start + 10

                    if self.word_mode == "reveal":
                        text = "".join(decorated[: i + 1])
                    else:
                        parts = list(decorated)
                        parts[i] = self._highlighted_word(w)
                        text = "".join(parts)

                    events.append(
                        SSAEvent(
                            start=start,
                            end=end,
                            style=self.ass_style_name,
                            text=text,
                        )
                    )
            else:
                events.append(
                    SSAEvent(
                        start=self.ms(line[0]["start"]),
                        end=line_end,
                        style=self.ass_style_name,
                        text=self.fade + "".join(decorated),
                    )
                )
        return events

    # --- Grouping ---

    def group_words(
        self,
        words: list[dict],
        max_words: int | None = None,
        max_duration: float | None = None,
    ) -> list[list[dict]]:
        """Group words into caption cards, bounded by this style's geometry."""
        return group_words_into_cards(
            words,
            max_words=self.max_words if max_words is None else max_words,
            max_duration=self.max_duration if max_duration is None else max_duration,
            max_chars=self.max_chars,
        )

    @staticmethod
    def ms(seconds: float) -> int:
        """Convert seconds to milliseconds for pysubs2."""
        return int(seconds * 1000)
