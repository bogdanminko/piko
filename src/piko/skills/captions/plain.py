"""Plain subtitle files — .srt and .vtt.

The cheapest rung of the export ladder and the only one every player,
platform and editor reads. Deliberately unstyled: this is the file you hand
to YouTube or drop onto a DaVinci timeline, not the look. It is also the
only export that costs nothing — no re-encode, no second copy of the video —
which is why it should never sit behind one.

Card boundaries come from the same rule the burned-in styles use, so the
file breaks where the picture breaks. Only the limits differ: reading
subtitles want longer lines and longer holds than a four-word caption card.
"""

from __future__ import annotations

from pathlib import Path

import pysubs2

from .styles.base import group_words_into_cards

# Broadcast convention, and what YouTube and Vimeo expect.
MAX_CHARS_PER_LINE = 42
MAX_LINES = 2
MAX_WORDS = 14
MAX_DURATION = 6.0
MIN_DURATION = 0.9

FORMATS = ("srt", "vtt")


def _words_from(segments: list[dict]) -> list[dict]:
    """Flatten word timings, falling back to whole segments without them.

    An ASR pass can return segments with no per-word timing at all; those
    still make perfectly good reading subtitles, just coarser ones.
    """
    words: list[dict] = []
    for segment in segments:
        segment_words = segment.get("words") or []
        if segment_words:
            words.extend(segment_words)
            continue
        text = (segment.get("text") or "").strip()
        if text:
            words.append(
                {
                    "word": text,
                    "start": float(segment.get("start", 0.0)),
                    "end": float(segment.get("end", 0.0)),
                }
            )
    return words


def wrap_lines(text: str, max_chars: int = MAX_CHARS_PER_LINE, max_lines: int = MAX_LINES) -> str:
    """Greedy wrap to at most `max_lines`; the last line absorbs the rest."""
    words = text.split()
    if not words:
        return ""

    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        if len(lines) + 1 >= max_lines:
            current = f"{current} {word}"
        elif len(current) + 1 + len(word) <= max_chars:
            current = f"{current} {word}"
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return "\\N".join(lines)


def build_plain_subtitles(segments: list[dict]) -> pysubs2.SSAFile:
    """Unstyled subtitle cards from transcription segments."""
    subs = pysubs2.SSAFile()
    cards = group_words_into_cards(
        _words_from(segments),
        max_words=MAX_WORDS,
        max_duration=MAX_DURATION,
        max_chars=MAX_CHARS_PER_LINE * MAX_LINES,
    )

    for index, card in enumerate(cards):
        text = wrap_lines(" ".join(w["word"].strip() for w in card if w["word"].strip()))
        if not text:
            continue

        start = float(card[0]["start"])
        end = float(card[-1]["end"])
        # A card too short to read is held longer — but never past the next
        # one, which would put two lines on screen at once.
        if end - start < MIN_DURATION:
            end = start + MIN_DURATION
            if index + 1 < len(cards):
                end = min(end, float(cards[index + 1][0]["start"]))
        if end <= start:
            end = start + 0.1

        subs.events.append(
            pysubs2.SSAEvent(start=int(start * 1000), end=int(end * 1000), text=text)
        )

    return subs


def save_plain_subtitles(segments: list[dict], base_path: str | Path) -> dict[str, str]:
    """Write .srt and .vtt beside `base_path`. Returns {format: path}."""
    subs = build_plain_subtitles(segments)
    base = Path(base_path)
    base.parent.mkdir(parents=True, exist_ok=True)

    written: dict[str, str] = {}
    for fmt in FORMATS:
        path = base.with_suffix(f".{fmt}")
        subs.save(str(path), format_=fmt)
        written[fmt] = str(path)
    return written
