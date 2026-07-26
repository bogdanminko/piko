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
from piko.skills.meeting.speakers import SPEAKER_ME, SPEAKER_THEM, SPEAKER_UNKNOWN, attribute


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
