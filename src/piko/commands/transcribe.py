"""`transcribe` command — slow Whisper pass, cached on disk."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from ..cache import CACHE_DIR
from ..core.media import extract_audio, get_video_duration
from ..core.memory import InsufficientMemoryError
from ..protocol import emit

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


def format_clock(seconds: float) -> str:
    """65.3 -> "01:05"."""
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"


def _transcription_cache_path(video_path: str, model: str, language: str | None) -> Path:
    """Cache key: video identity (path + mtime) + model + language."""
    p = Path(video_path)
    mtime = p.stat().st_mtime_ns if p.exists() else 0
    key = f"{p.resolve()}:{mtime}:{model}:{language or 'auto'}"
    digest = hashlib.sha1(key.encode(), usedforsecurity=False).hexdigest()[:16]
    return CACHE_DIR / "transcriptions" / f"{digest}.json"


def transcribe_video(video_path: str, model: str, language: str | None) -> dict:
    """Transcribe a video, using the cache if available.

    Returns dict: {"language": ..., "segments": [...], "path": <cache file>}.
    """
    cache_path = _transcription_cache_path(video_path, model, language)
    if cache_path.exists():
        data = json.loads(cache_path.read_text())
        data["path"] = str(cache_path)
        data["cached"] = True
        return data

    from ..core.transcriber import transcribe  # slow import (mlx)

    emit(
        {"type": "progress", "stage": "extracting", "percent": 0, "message": "Extracting audio..."}
    )
    audio_path = extract_audio(video_path)

    try:
        emit(
            {
                "type": "progress",
                "stage": "transcribing",
                "percent": 10,
                "message": "Transcribing audio...",
            }
        )

        # Realtime "processed X of Y" driven by mlx_whisper's per-segment
        # verbose output; throttled to one event per second of audio.
        duration = max(get_video_duration(video_path), 0.1)
        last_reported = 0.0

        def on_progress(seconds: float) -> None:
            nonlocal last_reported
            if seconds - last_reported < 1.0:
                return
            last_reported = seconds
            emit(
                {
                    "type": "progress",
                    "stage": "transcribing",
                    "percent": round(min(10 + seconds / duration * 88, 98), 1),
                    "message": (f"Transcribing {format_clock(seconds)} / {format_clock(duration)}"),
                    "processed_seconds": round(seconds, 1),
                    "total_seconds": round(duration, 1),
                }
            )

        result = transcribe(
            str(audio_path), model=model, language=language, progress_callback=on_progress
        )
    finally:
        audio_path.unlink(missing_ok=True)
        audio_path.parent.rmdir()

    data = {
        "language": result.get("language", "unknown"),
        "segments": result.get("segments", []),
    }
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(data, ensure_ascii=False))
    data["path"] = str(cache_path)
    data["cached"] = False
    return data


def count_words(segments: list[dict]) -> int:
    return sum(len(s.get("words", [])) for s in segments)


def handle_transcribe(params: dict) -> None:
    """Transcribe only; result carries transcription_path for later renders."""
    video_path = params["video_path"]
    model = params.get("model", DEFAULT_MODEL)
    language = params.get("language")

    try:
        data = transcribe_video(video_path, model, language)
        emit(
            {
                "type": "result",
                "success": True,
                "transcription_path": data["path"],
                "language": data["language"],
                "word_count": count_words(data["segments"]),
                "cached": data["cached"],
            }
        )
    except InsufficientMemoryError as e:
        emit({"type": "error", "message": str(e), "code": "INSUFFICIENT_MEMORY"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
