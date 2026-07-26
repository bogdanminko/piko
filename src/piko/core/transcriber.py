"""Whisper MLX transcription wrapper."""

from __future__ import annotations

import re
import subprocess
import sys
from collections.abc import Callable
from contextlib import redirect_stdout

import mlx_whisper

from .media import get_video_duration
from .memory import estimate_transcribe_peak_mb, requires_memory

# Segment lines mlx_whisper prints in verbose mode:
# "[00:12.000 --> 00:15.480] text" (hours appear for long audio).
_SEGMENT_END_RE = re.compile(r"--> (\d[\d:]*\.\d{3})]")


def _timestamp_to_seconds(stamp: str) -> float:
    parts = stamp.split(":")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


class _SegmentProgressWriter:
    """stdout sink for mlx_whisper's verbose output: swallows the text but
    reports each decoded segment's end time, giving realtime progress."""

    def __init__(self, callback: Callable[[float], None]) -> None:
        self._callback = callback
        self._buffer = ""

    def write(self, text: str) -> int:
        self._buffer += text
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            match = _SEGMENT_END_RE.search(line)
            if match:
                self._callback(_timestamp_to_seconds(match.group(1)))
        return len(text)

    def flush(self) -> None:
        pass


def _transcribe_estimate(
    audio_path: str,
    model: str = "mlx-community/whisper-large-v3-turbo",
    language: str | None = None,
    progress_callback: Callable[[float], None] | None = None,
) -> tuple[float, str]:
    """Peak-RAM estimate for the transcribe() call below (same signature)."""
    try:
        duration = get_video_duration(audio_path)
    except (OSError, subprocess.SubprocessError, ValueError):
        duration = 0.0  # unreadable file fails later with a clearer error
    needed_mb = estimate_transcribe_peak_mb(model, duration)
    what = f"{model.rsplit('/', 1)[-1]} + {duration / 60:.0f} min of audio"
    return needed_mb, what


def transcribe(
    audio_path: str,
    model: str = "mlx-community/parakeet-tdt-0.6b-v3",
    language: str | None = None,
    progress_callback: Callable[[float], None] | None = None,
) -> dict:
    """Transcribe audio/video file, dispatching to the model's engine.

    Parakeet models run through mlx-audio (see parakeet_transcriber.py);
    everything else runs through MLX Whisper below. Returns dict with
    keys: text, language (Whisper only), segments — each segment contains
    words with word, start, end, and (Whisper only) probability.
    """
    if "parakeet" in model.lower():
        from .parakeet_transcriber import transcribe as _transcribe_parakeet

        return _transcribe_parakeet(
            audio_path, model=model, language=language, progress_callback=progress_callback
        )
    return _transcribe_whisper(
        audio_path, model=model, language=language, progress_callback=progress_callback
    )


@requires_memory(_transcribe_estimate)
def _transcribe_whisper(
    audio_path: str,
    model: str = "mlx-community/whisper-large-v3-turbo",
    language: str | None = None,
    progress_callback: Callable[[float], None] | None = None,
) -> dict:
    """Transcribe audio/video file using MLX Whisper.

    Returns dict with keys: text, language, segments.
    Each segment contains words with: word, start, end, probability.

    stdout is redirected during transcription: stdout carries the JSON
    protocol for the app, and mlx_whisper prints status lines that would
    corrupt it. With a progress_callback, verbose mode is enabled and its
    per-segment lines are parsed into "seconds of audio done" callbacks.
    """
    if progress_callback is None:
        with redirect_stdout(sys.stderr):
            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=model,
                word_timestamps=True,
                language=language,
                verbose=False,
            )
        return result

    with redirect_stdout(_SegmentProgressWriter(progress_callback)):
        return mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo=model,
            word_timestamps=True,
            language=language,
            verbose=True,
        )
