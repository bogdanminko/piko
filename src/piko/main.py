"""Main entry point — JSON stdin/stdout protocol for SwiftUI integration."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from .subtitle_generator import generate_subtitles
from .video_processor import (
    burn_subtitles,
    extract_audio,
    get_video_duration,
    get_video_resolution,
)

CACHE_DIR = Path.home() / "Library" / "Caches" / "piko"


def emit(msg: dict) -> None:
    """Write JSON message to stdout (for SwiftUI to read)."""
    print(json.dumps(msg, ensure_ascii=False), flush=True)


# --- Transcription (slow, cached) ---

def _transcription_cache_path(video_path: str, model: str, language: str | None) -> Path:
    """Cache key: video identity (path + mtime) + model + language."""
    p = Path(video_path)
    mtime = p.stat().st_mtime_ns if p.exists() else 0
    key = f"{p.resolve()}:{mtime}:{model}:{language or 'auto'}"
    digest = hashlib.sha1(key.encode()).hexdigest()[:16]
    return CACHE_DIR / "transcriptions" / f"{digest}.json"


def _transcribe_video(video_path: str, model: str, language: str | None) -> dict:
    """Transcribe a video, using the cache if available.

    Returns dict: {"language": ..., "segments": [...], "path": <cache file>}.
    """
    cache_path = _transcription_cache_path(video_path, model, language)
    if cache_path.exists():
        data = json.loads(cache_path.read_text())
        data["path"] = str(cache_path)
        data["cached"] = True
        return data

    from .transcriber import transcribe  # slow import (mlx)

    emit({"type": "progress", "stage": "extracting", "percent": 0,
          "message": "Extracting audio..."})
    audio_path = extract_audio(video_path)

    try:
        emit({"type": "progress", "stage": "transcribing", "percent": 10,
              "message": "Transcribing audio..."})
        result = transcribe(str(audio_path), model=model, language=language)
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


def _count_words(segments: list[dict]) -> int:
    return sum(len(s.get("words", [])) for s in segments)


def handle_transcribe(params: dict) -> None:
    """Transcribe only; result carries transcription_path for later renders."""
    video_path = params["video_path"]
    model = params.get("model", "mlx-community/whisper-large-v3-mlx-8bit")
    language = params.get("language")

    try:
        data = _transcribe_video(video_path, model, language)
        emit({
            "type": "result",
            "success": True,
            "transcription_path": data["path"],
            "language": data["language"],
            "word_count": _count_words(data["segments"]),
            "cached": data["cached"],
        })
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


# --- Rendering (fast, repeatable with different styles) ---

def _render(video_path: str, segments: list[dict], language: str,
            style: str, output_path: str, subtitle_only: bool,
            word_mode: str = "static",
            highlight_color: str | None = None) -> None:
    """Generate .ass for the style and burn it into the video."""
    width, height = get_video_resolution(video_path)

    emit({"type": "progress", "stage": "subtitles", "percent": 5,
          "message": "Generating subtitles..."})
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    ass_path = Path(output_path).with_suffix(".ass")
    subs, emoji_timeline = generate_subtitles(
        segments, style_name=style, output_path=ass_path,
        video_width=width, video_height=height,
        word_mode=word_mode, highlight_color=highlight_color,
    )

    if not subtitle_only:
        emit({"type": "progress", "stage": "burning", "percent": 10,
              "message": "Burning subtitles into video..."})
        duration = max(get_video_duration(video_path), 0.1)

        from .emoji_renderer import render_emoji

        overlays = [
            {"png": render_emoji(e["emoji"], CACHE_DIR / "emoji"),
             "start": e["start"], "end": e["end"]}
            for e in emoji_timeline
        ]

        def on_progress(seconds: float) -> None:
            pct = min(10 + (seconds / duration) * 89, 99)
            emit({"type": "progress", "stage": "burning",
                  "percent": round(pct, 1),
                  "message": "Burning subtitles..."})

        burn_subtitles(video_path, ass_path, output_path,
                       progress_callback=on_progress,
                       emoji_overlays=overlays, video_height=height)

    markers = ("\\c&H00FFFF&", "\\c&H0000FF&", "\\c&H00FF00&", "\\i1")
    keyword_count = sum(
        1 for e in subs.events if any(m in e.text for m in markers)
    )
    emit({
        "type": "result",
        "success": True,
        "output_path": str(output_path),
        "subtitle_path": str(ass_path),
        "language": language,
        "style": style,
        "word_count": _count_words(segments),
        "keywords_found": keyword_count,
    })


def handle_render(params: dict) -> None:
    """Render subtitles from an existing transcription (no Whisper run)."""
    video_path = params["video_path"]
    transcription_path = params["transcription_path"]
    style = params.get("style", "mrbeast")
    output_path = params.get("output_path")
    subtitle_only = params.get("subtitle_only", False)
    word_mode = params.get("word_mode", "static")
    highlight_color = params.get("highlight_color")

    if not output_path:
        p = Path(video_path)
        output_path = str(p.parent / "piko_output"
                          / f"{p.stem}_subtitled_{style}{p.suffix}")

    try:
        data = json.loads(Path(transcription_path).read_text())
        _render(video_path, data["segments"], data.get("language", "unknown"),
                style, output_path, subtitle_only,
                word_mode=word_mode, highlight_color=highlight_color)
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_process(params: dict) -> None:
    """Full pipeline: transcribe (cached) + render. Kept for CLI use."""
    video_path = params["video_path"]
    style = params.get("style", "mrbeast")
    model = params.get("model", "mlx-community/whisper-large-v3-mlx-8bit")
    language = params.get("language")
    output_path = params.get("output_path")
    subtitle_only = params.get("subtitle_only", False)

    if not output_path:
        p = Path(video_path)
        output_path = str(p.parent / "piko_output"
                          / f"{p.stem}_subtitled{p.suffix}")

    try:
        data = _transcribe_video(video_path, model, language)
        _render(video_path, data["segments"], data["language"],
                style, output_path, subtitle_only,
                word_mode=params.get("word_mode", "static"),
                highlight_color=params.get("highlight_color"))
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


# --- Style previews ---

def handle_style_previews(params: dict) -> None:
    """Render preview PNGs (sample subtitle on black) for every style."""
    from .preview import generate_style_previews

    output_dir = params.get("output_dir") or str(CACHE_DIR / "previews")
    force = params.get("force", False)

    try:
        previews = generate_style_previews(output_dir, force=force)
        emit({"type": "result", "success": True, "previews": previews})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


# --- Model management ---

def handle_list_models() -> None:
    """List available Whisper models and their download status."""
    from huggingface_hub import scan_cache_dir

    models_info = [
        {"id": "mlx-community/whisper-large-v3-mlx-8bit", "name": "Large V3 (8-bit)", "size_mb": 1600},
        {"id": "mlx-community/whisper-large-v3-turbo", "name": "Large V3 Turbo", "size_mb": 1500},
        {"id": "mlx-community/whisper-large-v3-mlx-4bit", "name": "Large V3 (4-bit)", "size_mb": 900},
        {"id": "mlx-community/whisper-medium-mlx", "name": "Medium", "size_mb": 1500},
        {"id": "mlx-community/whisper-tiny", "name": "Tiny", "size_mb": 75},
    ]

    try:
        cache_info = scan_cache_dir()
        downloaded_repos = {r.repo_id for r in cache_info.repos}
    except Exception:
        downloaded_repos = set()

    for m in models_info:
        m["downloaded"] = m["id"] in downloaded_repos

    emit({"type": "models", "models": models_info})


def handle_download_model(params: dict) -> None:
    """Download a Whisper model from HuggingFace."""
    from huggingface_hub import snapshot_download

    model_id = params["model"]
    emit({"type": "progress", "stage": "downloading", "percent": 0,
          "message": f"Downloading {model_id}..."})

    try:
        path = snapshot_download(repo_id=model_id)
        emit({"type": "progress", "stage": "downloading", "percent": 100,
              "message": "Download complete"})
        emit({"type": "result", "success": True,
              "message": f"Model downloaded to {path}"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": "DOWNLOAD_ERROR"})


def handle_check_model(params: dict) -> None:
    """Check if a specific model is downloaded."""
    from huggingface_hub import scan_cache_dir

    model_id = params["model"]
    try:
        cache_info = scan_cache_dir()
        downloaded = any(r.repo_id == model_id for r in cache_info.repos)
    except Exception:
        downloaded = False

    emit({"type": "result", "success": True, "downloaded": downloaded,
          "model": model_id})


def main() -> None:
    """Read JSON command from stdin and dispatch."""
    raw = sys.stdin.read()
    if not raw.strip():
        emit({"type": "error", "message": "No input received", "code": "NO_INPUT"})
        return

    try:
        command = json.loads(raw)
    except json.JSONDecodeError as e:
        emit({"type": "error", "message": f"Invalid JSON: {e}", "code": "JSON_ERROR"})
        return

    cmd = command.get("command")
    params = command.get("params", {})

    handlers = {
        "process": handle_process,
        "transcribe": handle_transcribe,
        "render": handle_render,
        "style_previews": handle_style_previews,
        "list_models": lambda p: handle_list_models(),
        "download_model": handle_download_model,
        "check_model": handle_check_model,
    }

    handler = handlers.get(cmd)
    if handler:
        handler(params)
    else:
        emit({"type": "error", "message": f"Unknown command: {cmd}",
              "code": "UNKNOWN_COMMAND"})


if __name__ == "__main__":
    main()
