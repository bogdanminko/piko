"""Meeting recording commands — everything between "Stop" and a transcript.

`finalize_recording` turns the two raw tracks the recorder left on disk into
playable audio; `transcribe_meeting` transcribes the mix once and labels every
segment with the side that spoke it. Both are idempotent: they can be re-run on
the same folder without redoing finished work.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from ..core.llm import SamplingParams, pool
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
from ..skills.meeting.diarize import Turn, diarize
from ..skills.meeting.speakers import attribute, speaker_names
from ..skills.meeting.summary import summarize
from .transcribe import DEFAULT_MODEL, count_words, transcribe_video

# Stage → what the user sees while the summary runs.
_SUMMARY_STAGES = {
    "extracting": "Reading through the transcript...",
    "summarizing": "Writing the summary...",
    "shortening": "Tightening it up...",
    "dating": "Working out the deadlines...",
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


def _started_at(folder: Path) -> str:
    """When the meeting was recorded, or "" — the date anchor is optional."""
    try:
        return str(_load_meta(folder).get("started_at", ""))
    except (OSError, ValueError):
        return ""


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


#: Percent and a line of what is happening, for the caller to emit.
ProgressFn = Callable[[int, str], None]


def finalize_recording(folder: Path, on_step: ProgressFn | None = None) -> dict:
    """Encode both tracks, mix them for playback, drop the raw PCM.

    Returns the updated metadata. Already-finalized folders pass through.

    `on_step` is reported per encode rather than left to the caller's single
    "preparing…" at the start. Fifty minutes of raw PCM is around 200 MB across
    the two tracks, and a mix plus two AAC encodes over that takes long enough
    that a bar frozen at 10% is indistinguishable from an app that has died —
    which is exactly how it was reported.
    """
    meta = _load_meta(folder)
    raw = _raw_tracks(folder, meta)

    if not raw:
        return meta

    duration = max(track_duration(path) for path in raw.values())

    # One step for the mix, one per track. Named after what is happening so the
    # wait is legible rather than merely animated.
    steps = 1 + len(raw)
    done = 0

    def step(message: str) -> None:
        nonlocal done
        if on_step:
            on_step(10 + int(80 * done / steps), message)
        done += 1

    step(f"Mixing {duration / 60:.0f} min of audio…")
    # Mix from the raw tracks (lossless input) before they are removed. Track
    # order is fixed so a re-run produces the same file.
    ordered = [raw[name] for name in sorted(raw)]
    mix_tracks(ordered, folder / MIXED_FILE)

    for name, path in raw.items():
        step(f"Encoding the {name} track…")
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

    def report(percent: int, message: str) -> None:
        emit(
            {
                "type": "progress",
                "stage": "finalizing",
                "percent": percent,
                "message": message,
            }
        )

    try:
        report(5, "Preparing the recording...")
        meta = finalize_recording(folder, on_step=report)
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


def _reuse_transcription(path: str | None) -> dict | None:
    """A transcription of this same speech, already produced elsewhere.

    The cache is keyed on the file it was handed, and the two halves of the
    app hand it different files: captions transcribe the video itself, a
    meeting transcribes the `meeting.m4a` extracted from it. Same speech, same
    words, and without this the second reading pays for an entire ASR pass
    that has already been run — an hour of audio thrown away on a click.

    Only ever a *reuse*, never a fallback: a missing or unreadable file drops
    through to transcribing properly rather than failing.
    """
    if not path:
        return None
    source = Path(path)
    if not source.exists():
        return None
    try:
        data = json.loads(source.read_text())
    except (OSError, ValueError):
        return None
    if not data.get("segments"):
        return None
    return {
        "language": data.get("language", "unknown"),
        "segments": data["segments"],
        "path": str(source),
    }


def handle_transcribe_meeting(params: dict) -> None:
    """Transcribe a recorded meeting and label who spoke each segment."""
    folder = Path(params["recording_dir"])
    model = params.get("model", DEFAULT_MODEL)
    language = params.get("language")
    force = bool(params.get("force"))

    try:
        meta = finalize_recording(folder)
        mixed = folder / meta.get("mixed_file", MIXED_FILE)
        if not mixed.exists():
            raise FileNotFoundError(f"No mixed audio in {folder}")

        # `force` is the escape hatch for a transcript that came out wrong, so
        # it has to outrank the reuse as well as the cache.
        data = None if force else _reuse_transcription(params.get("transcription_path"))
        if data is not None:
            emit(
                {
                    "type": "progress",
                    "stage": "transcribing",
                    "percent": 95,
                    "message": "Reusing the transcript from this recording...",
                }
            )
        else:
            data = transcribe_video(str(mixed), model, language, force=force)

        tracks = meta.get("tracks", {})
        mic = load_samples(folder / tracks.get("mic", {}).get("file", "mic.m4a"))
        system = load_samples(folder / tracks.get("system", {}).get("file", "system.m4a"))

        # Telling individual voices apart is opt-in (`"diarize": true`), because
        # it is the one step here that downloads a model — 236 MB on first use —
        # and the app promises that nothing downloads until you ask. It is also
        # the expensive half: ~1 GB of peak memory on top of the transcriber.
        # Everything below works without it, just less specifically.
        #
        # A recording is diarized on its far-end track alone — the microphone
        # side is already settled physically, and a model can only unsettle it.
        # An import has no sides to settle, so there the mix is all there is.
        # With a mic track but no system track every segment is already "me",
        # so there is nobody left to tell apart and the model is skipped.
        voices = system if system.size else (mic[:0] if mic.size else load_samples(mixed))
        turns: list[Turn] = []
        if voices.size and params.get("diarize"):
            emit(
                {
                    "type": "progress",
                    "stage": "diarizing",
                    "percent": 97,
                    "message": "Telling the speakers apart...",
                }
            )
            turns = diarize(voices)

        emit(
            {
                "type": "progress",
                "stage": "attributing",
                "percent": 99,
                "message": "Matching voices to speakers...",
            }
        )
        segments = attribute(data["segments"], mic, system, turns=turns)

        transcript = {
            "version": 1,
            "language": data["language"],
            "duration": meta.get("duration", 0.0),
            "speakers": speaker_names(segments),
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

        # The day of the meeting is the anchor spoken deadlines resolve against
        # ("by Friday" → a real date). It comes from the recording itself, not
        # from today's date: a call summarized a week later must not shift.
        meeting_date = params.get("meeting_date") or _started_at(folder)

        # Marked in use for the whole map-reduce: `acquire` happens once at the
        # top and the run can take minutes, so an idle timer keyed on
        # acquisition alone would free the weights mid-summary.
        with pool.in_use():
            summary = summarize(
                session,
                transcript.get("segments", []),
                speakers=transcript.get("speakers"),
                language=transcript.get("language"),
                output_language=params.get("output_language"),
                meeting_date=meeting_date or None,
                # The Models screen's sliders, clamped into their safe ranges
                # (core/llm/sampling.py). Absent keys keep their defaults, so an
                # untouched install summarizes exactly as before.
                sampling=SamplingParams.from_params(params),
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
