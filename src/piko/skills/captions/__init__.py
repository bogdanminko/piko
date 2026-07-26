"""Captions skill — viral-style animated subtitles burned into video.

Pipeline: word-level Whisper timestamps → keyword detection →
semantic colors/emoji → styled ASS events → ffmpeg burn-in.
"""

from __future__ import annotations

from .generator import generate_subtitles

__all__ = ["generate_subtitles"]
