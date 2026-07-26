"""Generate ASS subtitle files using pysubs2."""

from __future__ import annotations

from pathlib import Path

import pysubs2

from .emoji_mapper import get_emoji
from .keyword_detector import detect_keywords
from .semantic_colors import get_semantic
from .styles import STYLES

# How long an emoji overlay stays on screen after its word starts.
EMOJI_HOLD_SECONDS = 1.6


def generate_subtitles(
    segments: list[dict],
    style_name: str = "mrbeast",
    output_path: str | Path | None = None,
    video_width: int = 1920,
    video_height: int = 1080,
    word_mode: str = "static",
    highlight_color: str | None = None,
) -> tuple[pysubs2.SSAFile, list[dict]]:
    """Generate ASS subtitle file from Whisper transcription segments.

    1. Detect keywords
    2. Map emojis to keywords (returned as an overlay timeline — libass
       cannot render color emoji, so they are composited by ffmpeg instead
       of being embedded in the ASS text)
    3. Apply selected style
    4. Return (SSAFile, emoji_timeline); the file is optionally saved to disk

    Each emoji_timeline entry: {"emoji": str, "start": float, "end": float}.
    """
    # Detect keywords and build the emoji overlay timeline
    words = detect_keywords(segments)
    emoji_timeline: list[dict] = []
    for w in words:
        emoji = None

        # Semantic coloring (color words, fire/water/money...) applies to
        # every occurrence, independent of keyword detection.
        semantic = get_semantic(w["word"])
        if semantic:
            w["semantic_color"], emoji = semantic

        if emoji is None and w["is_keyword"]:
            emoji = get_emoji(w["word"])

        if emoji:
            emoji_timeline.append(
                {
                    "emoji": emoji,
                    "start": w["start"],
                    "end": w["start"] + EMOJI_HOLD_SECONDS,
                }
            )

    # Overlays share one screen position — trim each entry so it
    # disappears when the next emoji arrives instead of stacking.
    for cur, nxt in zip(emoji_timeline, emoji_timeline[1:], strict=False):
        cur["end"] = min(cur["end"], nxt["start"])

    # Create ASS file
    subs = pysubs2.SSAFile()
    subs.info["PlayResX"] = str(video_width)
    subs.info["PlayResY"] = str(video_height)

    # Get style instance
    style_cls = STYLES.get(style_name)
    if style_cls is None:
        available = ", ".join(STYLES.keys())
        raise ValueError(f"Unknown style '{style_name}'. Available: {available}")

    style = style_cls(
        video_width, video_height, word_mode=word_mode, highlight_color=highlight_color
    )

    # Register styles
    for name, ssa_style in style.get_styles().items():
        subs.styles[name] = ssa_style

    # Generate events
    for event in style.generate_events(words):
        subs.events.append(event)

    if output_path:
        subs.save(str(output_path))

    return subs, emoji_timeline
