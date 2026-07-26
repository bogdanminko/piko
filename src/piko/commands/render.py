"""`render` and `process` commands — captions skill over the protocol."""

from __future__ import annotations

import json
from pathlib import Path

from ..cache import CACHE_DIR
from ..core.media import burn_subtitles, get_video_duration, get_video_resolution
from ..protocol import emit
from ..skills.captions import generate_subtitles
from .transcribe import DEFAULT_MODEL, count_words, transcribe_video


def _render(
    video_path: str,
    segments: list[dict],
    language: str,
    style: str,
    output_path: str,
    subtitle_only: bool,
    word_mode: str = "static",
    highlight_color: str | None = None,
) -> None:
    """Generate .ass for the style and burn it into the video."""
    width, height = get_video_resolution(video_path)

    emit(
        {
            "type": "progress",
            "stage": "subtitles",
            "percent": 5,
            "message": "Generating subtitles...",
        }
    )
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    ass_path = Path(output_path).with_suffix(".ass")
    subs, emoji_timeline = generate_subtitles(
        segments,
        style_name=style,
        output_path=ass_path,
        video_width=width,
        video_height=height,
        word_mode=word_mode,
        highlight_color=highlight_color,
    )

    if not subtitle_only:
        emit(
            {
                "type": "progress",
                "stage": "burning",
                "percent": 10,
                "message": "Burning subtitles into video...",
            }
        )
        duration = max(get_video_duration(video_path), 0.1)

        from ..skills.captions.emoji_renderer import render_emoji

        overlays = [
            {
                "png": render_emoji(e["emoji"], CACHE_DIR / "emoji"),
                "start": e["start"],
                "end": e["end"],
            }
            for e in emoji_timeline
        ]

        def on_progress(seconds: float) -> None:
            pct = min(10 + (seconds / duration) * 89, 99)
            emit(
                {
                    "type": "progress",
                    "stage": "burning",
                    "percent": round(pct, 1),
                    "message": "Burning subtitles...",
                }
            )

        burn_subtitles(
            video_path,
            ass_path,
            output_path,
            progress_callback=on_progress,
            emoji_overlays=overlays,
            video_height=height,
        )

    markers = ("\\c&H00FFFF&", "\\c&H0000FF&", "\\c&H00FF00&", "\\i1")
    keyword_count = sum(1 for e in subs.events if any(m in e.text for m in markers))
    emit(
        {
            "type": "result",
            "success": True,
            "output_path": str(output_path),
            "subtitle_path": str(ass_path),
            "language": language,
            "style": style,
            "word_count": count_words(segments),
            "keywords_found": keyword_count,
        }
    )


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
        output_path = str(p.parent / "piko_output" / f"{p.stem}_subtitled_{style}{p.suffix}")

    try:
        data = json.loads(Path(transcription_path).read_text())
        _render(
            video_path,
            data["segments"],
            data.get("language", "unknown"),
            style,
            output_path,
            subtitle_only,
            word_mode=word_mode,
            highlight_color=highlight_color,
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_process(params: dict) -> None:
    """Full pipeline: transcribe (cached) + render. Kept for CLI use."""
    video_path = params["video_path"]
    style = params.get("style", "mrbeast")
    model = params.get("model", DEFAULT_MODEL)
    language = params.get("language")
    output_path = params.get("output_path")
    subtitle_only = params.get("subtitle_only", False)

    if not output_path:
        p = Path(video_path)
        output_path = str(p.parent / "piko_output" / f"{p.stem}_subtitled{p.suffix}")

    try:
        data = transcribe_video(video_path, model, language)
        _render(
            video_path,
            data["segments"],
            data["language"],
            style,
            output_path,
            subtitle_only,
            word_mode=params.get("word_mode", "static"),
            highlight_color=params.get("highlight_color"),
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
