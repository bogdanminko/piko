"""Meeting recording commands — everything between "Stop" and a transcript.

`finalize_recording` turns the two raw tracks the recorder left on disk into
playable audio; `transcribe_meeting` transcribes the mix once and labels every
segment with the side that spoke it. Both are idempotent: they can be re-run on
the same folder without redoing finished work.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..core.llm import pool
from ..core.media import get_video_duration
from ..core.memory import InsufficientMemoryError
from ..protocol import emit
from ..skills.meeting.audio import (
    encode_track,
    extract_meeting_audio,
    load_samples,
    mix_tracks,
    track_duration,
)
from ..skills.meeting.speakers import SPEAKER_NAMES, attribute
from ..skills.meeting.summary import summarize
from .transcribe import DEFAULT_MODEL, count_words, transcribe_video

# Stage → what the user sees while the summary runs.
_SUMMARY_STAGES = {
    "extracting": "Reading through the transcript...",
    "summarizing": "Writing the summary...",
    "shortening": "Tightening it up...",
}

MIXED_FILE = "meeting.m4a"
TRANSCRIPT_FILE = "transcript.json"
SUMMARY_FILE = "summary.json"


def _load_meta(folder: Path) -> dict:
    meta_path = folder / "meta.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"No meta.json in {folder}")
    meta: dict = json.loads(meta_path.read_text())
    return meta


def _save_meta(folder: Path, meta: dict) -> None:
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))


def _raw_tracks(folder: Path, meta: dict) -> dict[str, Path]:
    """Track name → raw .pcm path, for the tracks not yet encoded."""
    tracks = {}
    for name, track in meta.get("tracks", {}).items():
        path = folder / track.get("file", "")
        if path.suffix == ".pcm" and path.exists():
            tracks[name] = path
    return tracks


def finalize_recording(folder: Path) -> dict:
    """Encode both tracks, mix them for playback, drop the raw PCM.

    Returns the updated metadata. Already-finalized folders pass through.
    """
    meta = _load_meta(folder)
    raw = _raw_tracks(folder, meta)

    if not raw:
        return meta

    duration = max(track_duration(path) for path in raw.values())

    # Mix from the raw tracks (lossless input) before they are removed. Track
    # order is fixed so a re-run produces the same file.
    ordered = [raw[name] for name in sorted(raw)]
    mix_tracks(ordered, folder / MIXED_FILE)

    for name, path in raw.items():
        encoded = encode_track(path, folder / f"{name}.m4a")
        meta["tracks"][name]["file"] = encoded.name

    meta["mixed_file"] = MIXED_FILE
    meta["duration"] = round(duration, 3)
    _save_meta(folder, meta)

    for path in raw.values():
        path.unlink(missing_ok=True)

    return meta


def handle_finalize_recording(params: dict) -> None:
    """Called right after Stop, before any transcription."""
    folder = Path(params["recording_dir"])

    try:
        emit(
            {
                "type": "progress",
                "stage": "finalizing",
                "percent": 10,
                "message": "Preparing the recording...",
            }
        )
        meta = finalize_recording(folder)
        emit(
            {
                "type": "result",
                "success": True,
                "output_path": str(folder / meta.get("mixed_file", MIXED_FILE)),
                "total_seconds": meta.get("duration", 0.0),
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_import_recording(params: dict) -> None:
    """Bring an existing file into the meeting pipeline.

    Anything ffmpeg reads works — mp4, mov, mkv, m4a, mp3, wav, opus. Only the
    audio is extracted into the meeting folder; the original file stays where
    the user put it and is never modified. From here on an import is
    indistinguishable from a recording, except that it has no side tracks, so
    every segment ends up labelled "Speaker" rather than guessed.
    """
    folder = Path(params["recording_dir"])
    source = Path(params["source_path"])

    try:
        if not source.exists():
            raise FileNotFoundError(f"No such file: {source}")

        emit(
            {
                "type": "progress",
                "stage": "importing",
                "percent": 10,
                "message": f"Reading {source.name}...",
            }
        )
        folder.mkdir(parents=True, exist_ok=True)
        extract_meeting_audio(source, folder / MIXED_FILE)

        meta = _load_meta(folder)
        meta["mixed_file"] = MIXED_FILE
        meta["source_file"] = str(source)
        meta["duration"] = round(get_video_duration(folder / MIXED_FILE), 3)
        _save_meta(folder, meta)

        emit(
            {
                "type": "result",
                "success": True,
                "output_path": str(folder / MIXED_FILE),
                "total_seconds": meta["duration"],
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_transcribe_meeting(params: dict) -> None:
    """Transcribe a recorded meeting and label who spoke each segment."""
    folder = Path(params["recording_dir"])
    model = params.get("model", DEFAULT_MODEL)
    language = params.get("language")

    try:
        meta = finalize_recording(folder)
        mixed = folder / meta.get("mixed_file", MIXED_FILE)
        if not mixed.exists():
            raise FileNotFoundError(f"No mixed audio in {folder}")

        data = transcribe_video(str(mixed), model, language, force=bool(params.get("force")))

        emit(
            {
                "type": "progress",
                "stage": "attributing",
                "percent": 99,
                "message": "Matching voices to speakers...",
            }
        )
        tracks = meta.get("tracks", {})
        mic = load_samples(folder / tracks.get("mic", {}).get("file", "mic.m4a"))
        system = load_samples(folder / tracks.get("system", {}).get("file", "system.m4a"))
        segments = attribute(data["segments"], mic, system)

        transcript = {
            "version": 1,
            "language": data["language"],
            "duration": meta.get("duration", 0.0),
            "speakers": SPEAKER_NAMES,
            "segments": segments,
        }
        transcript_path = folder / TRANSCRIPT_FILE
        transcript_path.write_text(json.dumps(transcript, ensure_ascii=False, indent=2))

        emit(
            {
                "type": "result",
                "success": True,
                "transcription_path": str(transcript_path),
                "output_path": str(mixed),
                "language": data["language"],
                "word_count": count_words(data["segments"]),
                "total_seconds": meta.get("duration", 0.0),
                "cached": data["cached"],
            }
        )
    except InsufficientMemoryError as e:
        emit({"type": "error", "message": str(e), "code": "INSUFFICIENT_MEMORY"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def handle_summarize_meeting(params: dict) -> None:
    """Transcript → structured summary, cached next to it in the meeting folder.

    Idempotent like the rest of the pipeline: a folder that already has a
    summary returns it instead of paying for the model again. Pass
    `"force": true` to redo it after changing the tier or sampling.
    """
    folder = Path(params["recording_dir"])
    summary_path = folder / SUMMARY_FILE

    try:
        if summary_path.exists() and not params.get("force"):
            emit(
                {
                    "type": "result",
                    "success": True,
                    "summary_path": str(summary_path),
                    "summary": json.loads(summary_path.read_text()),
                    "cached": True,
                }
            )
            return

        transcript_path = folder / TRANSCRIPT_FILE
        if not transcript_path.exists():
            raise FileNotFoundError(f"No transcript in {folder} — transcribe it first")
        transcript = json.loads(transcript_path.read_text())

        emit(
            {
                "type": "progress",
                "stage": "loading",
                "percent": 2,
                "message": "Loading the summarizer...",
            }
        )
        # Reuses the warm model when the process has one (see core/llm/pool.py),
        # so a warmup fired during transcription pays off here.
        session = pool.acquire(params)

        def on_progress(stage: str, percent: float) -> None:
            emit(
                {
                    "type": "progress",
                    "stage": stage,
                    "percent": round(percent, 1),
                    "message": _SUMMARY_STAGES.get(stage, "Summarizing..."),
                }
            )

        summary = summarize(
            session,
            transcript.get("segments", []),
            speakers=transcript.get("speakers"),
            language=transcript.get("language"),
            output_language=params.get("output_language"),
            on_progress=on_progress,
        )
        summary["language"] = transcript.get("language", "unknown")
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2))

        emit(
            {
                "type": "result",
                "success": True,
                "summary_path": str(summary_path),
                "summary": summary,
                "cached": False,
            }
        )
    except InsufficientMemoryError as e:
        emit({"type": "error", "message": str(e), "code": "INSUFFICIENT_MEMORY"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
