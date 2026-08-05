"""Meeting skill: finalizing a recording and attributing speakers.

Synthetic tracks only — no Whisper here; transcription is exercised through
the shared `transcribe` path that the captions skill already covers.
"""

import json
import math
import struct
import subprocess
from pathlib import Path

import numpy as np
import pytest

from piko.commands.meeting import MIXED_FILE, finalize_recording, handle_import_recording
from piko.core.media import FFMPEG
from piko.skills.meeting.audio import RAW_RATE, load_samples
from piko.skills.meeting.diarize import Turn, diarize
from piko.skills.meeting.speakers import (
    SPEAKER_ME,
    SPEAKER_THEM,
    SPEAKER_UNKNOWN,
    attribute,
    speaker_names,
)


def _tone_track(path: Path, duration: float, loud_spans: list[tuple[float, float]]) -> None:
    """Write a raw 16 kHz mono track that is silent except inside the spans."""
    frames = int(duration * RAW_RATE)
    samples = []
    for index in range(frames):
        seconds = index / RAW_RATE
        loud = any(start <= seconds < end for start, end in loud_spans)
        value = 0.4 * math.sin(2 * math.pi * 220 * seconds) if loud else 0.0
        samples.append(int(value * 32767))
    path.write_bytes(struct.pack(f"<{frames}h", *samples))


@pytest.fixture
def recording(tmp_path: Path) -> Path:
    """A finished two-track recording: I speak first, they answer."""
    _tone_track(tmp_path / "mic.pcm", 6.0, [(0.5, 2.0)])
    _tone_track(tmp_path / "system.pcm", 6.0, [(3.0, 4.5)])
    meta = {
        "version": 1,
        "id": "test",
        "title": "Test meeting",
        "started_at": "2026-07-26T12:00:00Z",
        "duration": 0,
        "sample_rate": RAW_RATE,
        "format": "s16le",
        "tracks": {
            "mic": {"file": "mic.pcm", "device": "Test Mic"},
            "system": {"file": "system.pcm", "device": "Test Output"},
        },
    }
    (tmp_path / "meta.json").write_text(json.dumps(meta))
    return tmp_path


def test_finalize_encodes_tracks_and_mix(recording: Path):
    meta = finalize_recording(recording)

    assert (recording / MIXED_FILE).exists()
    assert (recording / "mic.m4a").exists()
    assert (recording / "system.m4a").exists()
    # Raw PCM is replaced, not kept alongside.
    assert not (recording / "mic.pcm").exists()
    assert meta["tracks"]["mic"]["file"] == "mic.m4a"
    assert meta["mixed_file"] == MIXED_FILE
    assert meta["duration"] == pytest.approx(6.0, abs=0.05)


def test_finalize_is_idempotent(recording: Path):
    first = finalize_recording(recording)
    second = finalize_recording(recording)
    assert first["tracks"] == second["tracks"]
    assert second["duration"] == pytest.approx(first["duration"])


def test_mixed_audio_keeps_both_sides(recording: Path):
    finalize_recording(recording)
    mixed = load_samples(recording / MIXED_FILE)

    def level(start: float, end: float) -> float:
        chunk = mixed[int(start * RAW_RATE) : int(end * RAW_RATE)]
        return float(np.sqrt((chunk**2).mean()))

    assert level(0.8, 1.8) > 0.05  # my half
    assert level(3.2, 4.3) > 0.05  # their half
    assert level(2.2, 2.8) < 0.01  # the gap stays quiet


def test_attribution_follows_the_louder_track(recording: Path):
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")
    segments = [
        {"start": 0.6, "end": 1.9, "text": "my question"},
        {"start": 3.1, "end": 4.4, "text": "their answer"},
    ]

    tagged = attribute(segments, mic, system)

    assert [segment["speaker"] for segment in tagged] == [SPEAKER_ME, SPEAKER_THEM]
    assert all(segment["speaker_confidence"] > 0 for segment in tagged)


def test_import_extracts_audio_without_touching_the_original(tmp_path: Path, capsys):
    """An imported file joins the same pipeline; the source is left alone."""
    source_dir = tmp_path / "elsewhere"
    source_dir.mkdir()
    raw = source_dir / "call.pcm"
    _tone_track(raw, 4.0, [(0.5, 3.5)])
    source = source_dir / "call.wav"
    subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-f",
            "s16le",
            "-ar",
            str(RAW_RATE),
            "-ac",
            "1",
            "-i",
            str(raw),
            "-y",
            str(source),
        ],
        capture_output=True,
        check=True,
    )
    source_bytes = source.read_bytes()

    folder = tmp_path / "imported"
    folder.mkdir()
    (folder / "meta.json").write_text(
        json.dumps(
            {
                "version": 1,
                "id": "imported",
                "title": "call",
                "started_at": "2026-07-26T12:00:00Z",
                "duration": 0,
                "sample_rate": RAW_RATE,
                "format": "aac",
                "tracks": {},
            }
        )
    )

    handle_import_recording({"recording_dir": str(folder), "source_path": str(source)})

    result = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert result["success"] is True

    meta = json.loads((folder / "meta.json").read_text())
    assert meta["mixed_file"] == MIXED_FILE
    assert meta["source_file"] == str(source)
    assert meta["duration"] == pytest.approx(4.0, abs=0.15)
    assert (folder / MIXED_FILE).exists()
    assert source.read_bytes() == source_bytes


def test_imported_audio_has_no_guessed_speaker():
    """One source, no sides — labelling it "you" would be a guess."""
    silence = np.zeros(0, dtype=np.float32)
    tagged = attribute([{"start": 0.0, "end": 2.0, "text": "hello"}], silence, silence)

    assert tagged[0]["speaker"] == SPEAKER_UNKNOWN
    assert tagged[0]["speaker_confidence"] == 0


def test_single_track_recording_is_all_mine(recording: Path):
    mic = load_samples(recording / "mic.pcm")
    segments = [{"start": 0.6, "end": 1.9, "text": "solo note"}]

    tagged = attribute(segments, mic, np.zeros(0, dtype=np.float32))

    assert tagged[0]["speaker"] == SPEAKER_ME


def test_far_end_voices_are_numbered(recording: Path):
    """Diarization narrows "them" to the person who owns most of the segment."""
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")
    segments = [
        {"start": 0.6, "end": 1.9, "text": "my question"},
        {"start": 3.1, "end": 4.4, "text": "their answer"},
    ]
    # Slot 2 speaks first: the numbering must present it as Participant 1, with
    # no gap where the unused slots were.
    turns = [Turn(start=3.0, end=3.6, speaker=2), Turn(start=3.6, end=4.5, speaker=0)]

    tagged = attribute(segments, mic, system, turns=turns)

    assert tagged[0]["speaker"] == SPEAKER_ME
    assert tagged[1]["speaker"] == "them-2"  # slot 0 holds 0.8s of it vs slot 2's 0.5s
    assert speaker_names(tagged)["them-2"] == "Participant 2"


def test_unresolved_far_end_segment_keeps_the_collective_label(recording: Path):
    """A segment no turn touches stays "them" rather than joining a neighbour."""
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")
    segments = [{"start": 3.1, "end": 4.4, "text": "their answer"}]

    tagged = attribute(segments, mic, system, turns=[Turn(start=9.0, end=9.5, speaker=0)])

    assert tagged[0]["speaker"] == SPEAKER_THEM
    assert speaker_names(tagged)["them"] == "Participants"


def test_imported_audio_numbers_voices_without_placing_them():
    """An import has no sides, so its voices are "Speaker N" — never "You"."""
    silence = np.zeros(0, dtype=np.float32)
    segments = [
        {"start": 0.0, "end": 2.0, "text": "hello"},
        {"start": 2.0, "end": 4.0, "text": "hi there"},
    ]
    turns = [Turn(start=0.0, end=2.0, speaker=1), Turn(start=2.0, end=4.0, speaker=3)]

    tagged = attribute(segments, silence, silence, turns=turns)
    names = speaker_names(tagged)

    assert [segment["speaker"] for segment in tagged] == ["unknown-1", "unknown-2"]
    assert names["unknown-1"] == "Speaker 1"
    assert names["unknown-2"] == "Speaker 2"
    # No side was measured, so nothing here is claimed with confidence.
    assert all(segment["speaker_confidence"] == 0 for segment in tagged)


def test_diarization_of_an_empty_track_is_not_attempted():
    """No audio, no model load — and certainly no invented turns."""
    assert diarize(np.zeros(0, dtype=np.float32)) == []


def test_a_tie_goes_to_the_voice_that_was_actually_heard(recording: Path):
    """The reported bug: a colleague's line inherited "me" from the line before.

    The gap between the two utterances has no clear winner on either track, so
    the old rule handed it to whoever spoke last. Diarization heard someone on
    the far-end track through it, and hearing outranks inheriting.
    """
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")
    quiet = {"start": 2.2, "end": 2.8, "text": "their quiet line"}
    segments = [{"start": 0.6, "end": 1.9, "text": "my question"}, quiet]

    inherited = attribute(segments, mic, system)
    heard = attribute(segments, mic, system, turns=[Turn(start=2.0, end=3.0, speaker=0)])

    assert inherited[1]["speaker"] == SPEAKER_ME  # what the bug looked like
    assert heard[1]["speaker"] == "them-1"


def test_partial_far_end_coverage_still_inherits(recording: Path):
    """A turn brushing the edge of a tied segment is not enough to claim it."""
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")
    segments = [
        {"start": 0.6, "end": 1.9, "text": "my question"},
        {"start": 2.2, "end": 2.8, "text": "tied"},
    ]

    tagged = attribute(segments, mic, system, turns=[Turn(start=2.7, end=3.4, speaker=0)])

    assert tagged[1]["speaker"] == SPEAKER_ME


def test_an_undecidable_first_segment_is_not_credited_to_me(recording: Path):
    """With no previous decision, the ratio decides — not a hardcoded side."""
    mic = load_samples(recording / "mic.pcm")
    system = load_samples(recording / "system.pcm")

    tagged = attribute([{"start": 2.2, "end": 2.8, "text": "silence"}], mic, system)

    assert tagged[0]["speaker"] in {SPEAKER_ME, SPEAKER_THEM}
    assert tagged[0]["speaker_confidence"] < 0.08  # decided on a hair, and says so


# --- Reusing a transcript across the two readings of one file ---


def _write_transcription(path: Path) -> None:
    path.write_text(
        json.dumps(
            {
                "language": "en",
                "segments": [
                    {
                        "start": 0.5,
                        "end": 1.8,
                        "text": " Shipping on Friday.",
                        "words": [
                            {"word": " Shipping", "start": 0.5, "end": 1.1},
                            {"word": " on", "start": 1.15, "end": 1.3},
                            {"word": " Friday.", "start": 1.35, "end": 1.8},
                        ],
                    }
                ],
            }
        )
    )


def test_an_existing_transcript_is_reused(tmp_path: Path):
    """Dropping a video transcribes it; asking for a call summary afterwards
    must not pay for the identical ASR pass a second time."""
    from piko.commands.meeting import _reuse_transcription

    source = tmp_path / "cached.json"
    _write_transcription(source)

    data = _reuse_transcription(str(source))
    assert data is not None
    assert data["language"] == "en"
    assert data["segments"][0]["words"][0]["word"] == " Shipping"


@pytest.mark.parametrize(
    "content",
    [None, "", "{}", '{"segments": []}', "not json at all"],
    ids=["missing", "empty-file", "no-segments-key", "no-segments", "unparseable"],
)
def test_an_unusable_transcript_falls_through_to_transcribing(tmp_path: Path, content):
    """Reuse is an optimisation, never a substitute: anything it cannot read
    has to return None so the caller runs the model properly."""
    from piko.commands.meeting import _reuse_transcription

    if content is None:
        assert _reuse_transcription(str(tmp_path / "nope.json")) is None
        assert _reuse_transcription(None) is None
        return

    path = tmp_path / "broken.json"
    path.write_text(content)
    assert _reuse_transcription(str(path)) is None


# --- notes the user typed --------------------------------------------------
#
# `notes.json` is written by the app as each line is entered, in exactly the
# shape Piko/Models/MeetingNotes.swift encodes. The backend only reads it, and
# a meeting is worth summarizing whether or not it is there — so every failure
# to read it is "no notes", never an error.


def test_notes_are_read_in_the_shape_the_app_writes(tmp_path: Path):
    from piko.commands.meeting import _load_notes

    (tmp_path / "notes.json").write_text(
        json.dumps(
            {
                "version": 1,
                "notes": [
                    {
                        "id": "84E1",
                        "at": 12.5,
                        "text": "Kirill Zh., not Кирил",
                        "created_at": "2026-08-04T10:12:31Z",
                    },
                    {"id": "84E2", "at": None, "text": "no clock on an import"},
                ],
            }
        )
    )

    notes = _load_notes(tmp_path)
    assert [note["text"] for note in notes] == ["Kirill Zh., not Кирил", "no clock on an import"]
    assert notes[0]["at"] == 12.5


@pytest.mark.parametrize(
    "content",
    [None, "", "not json", "[]", "{}", '{"notes": "a string"}', '{"notes": [1, 2]}'],
    ids=["missing", "empty", "unparseable", "array", "no-key", "wrong-type", "not-objects"],
)
def test_an_unreadable_notes_file_is_a_meeting_without_notes(tmp_path: Path, content):
    from piko.commands.meeting import _load_notes

    if content is not None:
        (tmp_path / "notes.json").write_text(content)
    assert _load_notes(tmp_path) == []
