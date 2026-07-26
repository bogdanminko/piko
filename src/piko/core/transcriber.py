"""Whisper MLX transcription wrapper."""

from __future__ import annotations

import sys
from contextlib import redirect_stdout

import mlx_whisper


def transcribe(
    audio_path: str,
    model: str = "mlx-community/whisper-large-v3-mlx-8bit",
    language: str | None = None,
) -> dict:
    """Transcribe audio/video file using MLX Whisper.

    Returns dict with keys: text, language, segments.
    Each segment contains words with: word, start, end, probability.

    stdout is redirected to stderr during transcription: stdout carries the
    JSON protocol for the app, and mlx_whisper prints status lines
    (e.g. "Detected language: ...") that would corrupt it.
    """
    with redirect_stdout(sys.stderr):
        result = mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo=model,
            word_timestamps=True,
            language=language,
            verbose=False,
        )
    return result
