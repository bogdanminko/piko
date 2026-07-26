"""FFmpeg wrapper for audio extraction and subtitle burn-in."""

from __future__ import annotations

import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"


def get_video_resolution(video_path: str | Path) -> tuple[int, int]:
    """Get video width and height using ffprobe."""
    cmd = [
        FFPROBE,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0:s=x",
        str(video_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    w, h = result.stdout.strip().split("x")
    return int(w), int(h)


def get_video_duration(video_path: str | Path) -> float:
    """Get video duration in seconds using ffprobe."""
    cmd = [
        FFPROBE,
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "csv=p=0",
        str(video_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return float(result.stdout.strip())


def extract_audio(video_path: str | Path) -> Path:
    """Extract audio from video as WAV file in a temp directory."""
    tmp = Path(tempfile.mkdtemp(prefix="piko_"))
    audio_path = tmp / "audio.wav"

    cmd = [
        FFMPEG,
        "-i",
        str(video_path),
        "-vn",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        "-y",
        str(audio_path),
    ]
    subprocess.run(cmd, capture_output=True, check=True)
    return audio_path


def burn_subtitles(
    video_path: str | Path,
    ass_path: str | Path,
    output_path: str | Path,
    progress_callback: Callable[[float], None] | None = None,
    emoji_overlays: list[dict] | None = None,
    video_height: int = 1080,
) -> None:
    """Burn ASS subtitles into video using FFmpeg.

    emoji_overlays: [{"png": path, "start": s, "end": e}, ...] — composited
    centered above the subtitle block (libass cannot render color emoji).
    """
    # Escape paths for FFmpeg filter
    ass_str = str(ass_path).replace("\\", "/").replace(":", "\\:")
    ass_str = ass_str.replace("'", "\\'")

    inputs = ["-i", str(video_path)]
    if emoji_overlays:
        for ov in emoji_overlays:
            inputs += ["-i", str(ov["png"])]

        emoji_h = max(int(video_height * 0.09), 48)
        # Emoji sits above the subtitle text block (which hugs the bottom).
        y_expr = f"main_h-{int(video_height * 0.22)}-overlay_h"

        chains = []
        label = "base"
        chains.append(f"[0:v]ass='{ass_str}'[{label}]")
        for i, ov in enumerate(emoji_overlays):
            scaled = f"e{i}"
            chains.append(f"[{i + 1}:v]scale=-1:{emoji_h}[{scaled}]")
            nxt = f"v{i}" if i < len(emoji_overlays) - 1 else "out"
            chains.append(
                f"[{label}][{scaled}]overlay=x=(main_w-overlay_w)/2:y={y_expr}"
                f":enable='between(t,{ov['start']:.3f},{ov['end']:.3f})'[{nxt}]"
            )
            label = nxt
        filter_args = ["-filter_complex", ";".join(chains), "-map", "[out]", "-map", "0:a?"]
    else:
        filter_args = ["-vf", f"ass='{ass_str}'"]

    cmd = [
        FFMPEG,
        *inputs,
        *filter_args,
        "-c:a",
        "copy",
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "18",
        "-y",
        str(output_path),
    ]

    process = subprocess.Popen(
        cmd,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )

    if progress_callback and process.stderr:
        for line in process.stderr:
            if "time=" in line:
                # Parse time=HH:MM:SS.xx for progress
                try:
                    time_str = line.split("time=")[1].split(" ")[0]
                    parts = time_str.split(":")
                    seconds = float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
                    progress_callback(seconds)
                except (IndexError, ValueError):
                    pass

    process.wait()
    if process.returncode != 0:
        raise RuntimeError(f"FFmpeg failed with return code {process.returncode}")
