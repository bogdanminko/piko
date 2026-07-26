"""Render style preview thumbnails: sample subtitle on a black background."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import pysubs2

from ...core.media import FFMPEG
from .styles import STYLES

# Canvas matches the typical vertical-video resolution the styles target.
CANVAS_W = 1080
CANVAS_H = 1920
# Bottom strip that contains the subtitle for every style (marginv 40-80).
CROP_H = 340
# All sample events are active at this timestamp; karaoke/tiktok show
# mid-highlight state here.
FRAME_TIME = 1.5

SAMPLE_WORDS = [
    {"word": "This", "start": 0.4, "end": 0.8, "probability": 0.99},
    {"word": " is", "start": 0.8, "end": 1.1, "probability": 0.99},
    {"word": " amazing", "start": 1.1, "end": 1.9, "probability": 0.99, "is_keyword": True},
    {"word": " content", "start": 1.9, "end": 2.6, "probability": 0.99},
]
SAMPLE_EMOJI = "\U0001f525"


def _render_preview(style_name: str, out_path: Path, emoji_png: Path) -> None:
    """Render one style's sample subtitle to a PNG strip."""
    with tempfile.TemporaryDirectory(prefix="piko_preview_") as tmp:
        ass_path = Path(tmp) / f"{style_name}.ass"

        # Build the ASS file directly (bypassing detect_keywords):
        # sample words carry is_keyword already.
        style_cls = STYLES[style_name]
        style = style_cls(CANVAS_W, CANVAS_H)

        subs = pysubs2.SSAFile()
        subs.info["PlayResX"] = str(CANVAS_W)
        subs.info["PlayResY"] = str(CANVAS_H)
        for name, ssa_style in style.get_styles().items():
            subs.styles[name] = ssa_style
        for event in style.generate_events(SAMPLE_WORDS):
            subs.events.append(event)
        subs.save(str(ass_path))

        ass_str = str(ass_path).replace("\\", "/").replace(":", "\\:").replace("'", "\\'")
        crop_y = CANVAS_H - CROP_H
        cmd = [
            FFMPEG,
            "-f",
            "lavfi",
            "-i",
            f"color=c=black:s={CANVAS_W}x{CANVAS_H}:d=2",
            "-i",
            str(emoji_png),
            "-filter_complex",
            f"[0:v]ass='{ass_str}',crop={CANVAS_W}:{CROP_H}:0:{crop_y}[base];"
            f"[1:v]scale=-1:96[e];"
            f"[base][e]overlay=x=(main_w-overlay_w)/2:y=16",
            "-ss",
            str(FRAME_TIME),
            "-frames:v",
            "1",
            "-y",
            str(out_path),
        ]
        subprocess.run(cmd, capture_output=True, check=True)


def generate_style_previews(output_dir: str | Path, force: bool = False) -> dict[str, str]:
    """Render a preview PNG for every registered style.

    Returns mapping style_name -> png path. Existing files are reused
    unless force is set.
    """
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    from .emoji_renderer import render_emoji

    emoji_png = render_emoji(SAMPLE_EMOJI, out.parent / "emoji")

    previews: dict[str, str] = {}
    for style_name in STYLES:
        png = out / f"{style_name}.png"
        if force or not png.exists():
            _render_preview(style_name, png, emoji_png)
        previews[style_name] = str(png)
    return previews
