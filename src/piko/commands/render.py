"""`render` and `process` commands — captions skill over the protocol."""

from __future__ import annotations

import json
from pathlib import Path

from ..cache import CACHE_DIR
from ..core.media import burn_subtitles, get_video_duration, get_video_resolution
from ..core.memory import InsufficientMemoryError
from ..protocol import emit
from ..skills.captions import generate_subtitles, save_plain_subtitles
from ..skills.captions.keyword_detector import detect_keywords
from .transcribe import DEFAULT_MODEL, count_words, format_clock, transcribe_video


def _render(
    video_path: str,
    segments: list[dict],
    language: str,
    style: str,
    output_path: str,
    subtitle_only: bool,
    word_mode: str = "static",
    highlight_color: str | None = None,
    broll: bool = False,
) -> None:
    """Generate .ass for the style and burn it into the video."""
    width, height = get_video_resolution(video_path)

    # B-roll cut-ins are composed first, so subtitles burn on top of them.
    broll_temp: Path | None = None
    broll_count = 0
    if broll and not subtitle_only:
        from ..core.broll import BRollLibrary, compose_broll, plan_inserts

        inserts = plan_inserts(segments, BRollLibrary())
        if inserts:
            broll_count = len(inserts)
            emit(
                {
                    "type": "progress",
                    "stage": "broll",
                    "percent": 2,
                    "message": f"Inserting {broll_count} b-roll clips...",
                }
            )
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)
            broll_temp = Path(output_path).with_suffix(".broll.mp4")
            compose_broll(video_path, inserts, broll_temp)
            video_path = str(broll_temp)

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
    _, emoji_timeline = generate_subtitles(
        segments,
        style_name=style,
        output_path=ass_path,
        video_width=width,
        video_height=height,
        word_mode=word_mode,
        highlight_color=highlight_color,
    )

    # The cheapest rung of the export ladder, written every time: an .srt
    # costs nothing to produce and is the only subtitle file YouTube, Vimeo
    # and every editor read. It must never sit behind a re-encode.
    plain_paths = save_plain_subtitles(segments, ass_path)

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
                    "message": (
                        f"Burning subtitles {format_clock(seconds)} / {format_clock(duration)}"
                    ),
                    "processed_seconds": round(seconds, 1),
                    "total_seconds": round(duration, 1),
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

    if broll_temp is not None:
        broll_temp.unlink(missing_ok=True)

    # Counted from the detection itself rather than by grepping colour tags
    # out of the events: tiktok marks keywords with no tag at all (always
    # reported 0), hormozi's orange was not in the list, and reveal/highlight
    # repeat a keyword once per word in its card (reported several times).
    keyword_count = sum(1 for w in detect_keywords(segments) if w.get("is_keyword"))

    emit(
        {
            "type": "result",
            "success": True,
            # subtitle_only writes no video, so it must not claim one.
            "output_path": None if subtitle_only else str(output_path),
            "subtitle_path": str(ass_path),
            "srt_path": plain_paths["srt"],
            "vtt_path": plain_paths["vtt"],
            "language": language,
            "style": style,
            "word_count": count_words(segments),
            "keywords_found": keyword_count,
            "broll_inserts": broll_count,
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
            broll=params.get("broll", False),
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
            broll=params.get("broll", False),
        )
    except InsufficientMemoryError as e:
        emit({"type": "error", "message": str(e), "code": "INSUFFICIENT_MEMORY"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
