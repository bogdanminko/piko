"""Render emoji to transparent PNGs.

libass (used by ffmpeg's ass filter) cannot rasterize Apple Color Emoji,
so emojis are rendered to PNGs here and composited onto the video with
ffmpeg overlay filters instead of being embedded in the ASS text.
"""

from __future__ import annotations

from pathlib import Path

EMOJI_FONT = "/System/Library/Fonts/Apple Color Emoji.ttc"
# Apple Color Emoji is a bitmap (sbix) font; 160px is its largest strike.
STRIKE_SIZE = 160


def render_emoji(emoji: str, cache_dir: str | Path) -> Path:
    """Render a single emoji to a transparent PNG, cached by codepoints."""
    cache = Path(cache_dir)
    cache.mkdir(parents=True, exist_ok=True)

    name = "-".join(f"{ord(c):x}" for c in emoji)
    png = cache / f"{name}.png"
    if png.exists():
        return png

    from PIL import Image, ImageDraw, ImageFont

    font = ImageFont.truetype(EMOJI_FONT, STRIKE_SIZE)
    pad = 10
    img = Image.new("RGBA", (STRIKE_SIZE + pad * 2, STRIKE_SIZE + pad * 2), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.text((pad, pad), emoji, font=font, embedded_color=True)

    bbox = img.getbbox()
    if bbox:
        img = img.crop(bbox)
    img.save(png)
    return png
