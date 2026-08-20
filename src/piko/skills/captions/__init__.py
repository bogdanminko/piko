"""Captions skill — viral-style animated subtitles burned into video.

Pipeline: word-level Whisper timestamps → keyword detection →
semantic colors/emoji → styled ASS events → ffmpeg burn-in.
"""

from __future__ import annotations

from .generator import generate_subtitles
from .plain import build_plain_subtitles, save_plain_subtitles

__all__ = ["build_plain_subtitles", "generate_subtitles", "save_plain_subtitles"]
