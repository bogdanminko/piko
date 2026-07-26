"""Raw recording tracks in, playable audio and sample arrays out."""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

from ...core.media import FFMPEG

# The recorder writes both tracks in this format; see PCMTrackWriter.swift.
RAW_RATE = 16_000
RAW_FORMAT = "s16le"
RAW_BYTES_PER_FRAME = 2


def track_duration(raw_path: Path) -> float:
    """Seconds of audio in a raw track, straight from its size."""
    if not raw_path.exists():
        return 0.0
    return raw_path.stat().st_size / (RAW_BYTES_PER_FRAME * RAW_RATE)


def _raw_input_args(raw_path: Path) -> list[str]:
    return ["-f", RAW_FORMAT, "-ar", str(RAW_RATE), "-ac", "1", "-i", str(raw_path)]


def encode_track(raw_path: Path, output_path: Path) -> Path:
    """Raw PCM → m4a. Speech at 16 kHz mono needs very little bitrate."""
    cmd = [
        FFMPEG,
        "-v",
        "error",
        *_raw_input_args(raw_path),
        "-c:a",
        "aac",
        "-b:a",
        "48k",
        "-y",
        str(output_path),
    ]
    subprocess.run(cmd, capture_output=True, check=True)
    return output_path


def mix_tracks(raw_paths: list[Path], output_path: Path) -> Path:
    """Mix the raw tracks into one playable m4a — this is what gets transcribed.

    `amix` alone halves the level of each input, which costs the quieter side
    real transcription accuracy, so inputs are summed at full level
    (`normalize=0`) and a limiter catches the overlaps.
    """
    if not raw_paths:
        raise ValueError("no tracks to mix")

    cmd = [FFMPEG, "-v", "error"]
    for path in raw_paths:
        cmd += _raw_input_args(path)

    if len(raw_paths) == 1:
        cmd += ["-af", "alimiter=limit=0.95"]
    else:
        cmd += [
            "-filter_complex",
            f"amix=inputs={len(raw_paths)}:duration=longest:normalize=0,alimiter=limit=0.95",
        ]
    cmd += ["-c:a", "aac", "-b:a", "64k", "-y", str(output_path)]
    subprocess.run(cmd, capture_output=True, check=True)
    return output_path


def extract_meeting_audio(source_path: Path, output_path: Path) -> Path:
    """Any ffmpeg-readable file → the same m4a a recording produces.

    Video included: only the audio stream is taken (`-vn`), so importing an
    hour of 4K screen capture costs a few megabytes and the original is never
    copied or touched.
    """
    cmd = [
        FFMPEG,
        "-v",
        "error",
        "-i",
        str(source_path),
        "-vn",
        "-ac",
        "1",
        "-ar",
        str(RAW_RATE),
        "-c:a",
        "aac",
        "-b:a",
        "64k",
        "-y",
        str(output_path),
    ]
    subprocess.run(cmd, capture_output=True, check=True)
    return output_path


def load_samples(path: Path) -> np.ndarray:
    """Decode any track (raw or encoded) to mono float32 at 16 kHz."""
    if not path.exists():
        return np.zeros(0, dtype=np.float32)

    if path.suffix == ".pcm":
        data = np.frombuffer(path.read_bytes(), dtype=np.int16)
    else:
        cmd = [
            FFMPEG,
            "-v",
            "error",
            "-i",
            str(path),
            "-f",
            RAW_FORMAT,
            "-ac",
            "1",
            "-ar",
            str(RAW_RATE),
            "-",
        ]
        result = subprocess.run(cmd, capture_output=True, check=True)
        data = np.frombuffer(result.stdout, dtype=np.int16)

    return data.astype(np.float32) / 32768.0
