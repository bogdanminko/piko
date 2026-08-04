"""FFmpeg wrapper for audio extraction and subtitle burn-in."""

from __future__ import annotations

import json
import subprocess
import tempfile
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"

# Codecs an .mp4 carries without complaint. Anything else — opus, vorbis,
# flac, raw pcm — has to be transcoded: `-c:a copy` fails the whole burn,
# and the source of that failure used to be invisible.
MP4_AUDIO_CODECS = frozenset({"aac", "mp3", "alac", "ac3", "eac3"})

# How much of ffmpeg's stderr to keep so a failure can say what went wrong.
_ERROR_TAIL_LINES = 24


@dataclass(frozen=True)
class VideoInfo:
    """What the burn pipeline needs to know about an input file."""

    width: int  # as displayed — rotation already applied
    height: int
    rotation: int
    audio_codec: str | None


def _rotation_of(stream: dict) -> int:
    """Display rotation in degrees, from either the modern or legacy tag."""
    for side_data in stream.get("side_data_list") or []:
        if "rotation" in side_data:
            try:
                return int(round(float(side_data["rotation"]))) % 360
            except (TypeError, ValueError):
                pass
    legacy = (stream.get("tags") or {}).get("rotate")
    if legacy is not None:
        try:
            return int(round(float(legacy))) % 360
        except (TypeError, ValueError):
            pass
    return 0


def probe_video(video_path: str | Path) -> VideoInfo:
    """Probe display dimensions and audio codec in one ffprobe call."""
    cmd = [FFPROBE, "-v", "error", "-show_streams", "-of", "json", str(video_path)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    streams = json.loads(result.stdout).get("streams", [])

    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video is None:
        raise RuntimeError(f"No video stream in {video_path}")
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)

    width = int(video.get("width") or 0)
    height = int(video.get("height") or 0)
    rotation = _rotation_of(video)

    # ffprobe reports *coded* dimensions and ignores the display matrix,
    # while ffmpeg auto-rotates before the filter chain. A portrait clip
    # stored as 1920x1080 + 90° must be described to libass as 1080x1920,
    # or every subtitle is scaled along the wrong axis.
    if rotation % 180 == 90:
        width, height = height, width

    return VideoInfo(
        width=width,
        height=height,
        rotation=rotation,
        audio_codec=audio.get("codec_name") if audio else None,
    )


def get_video_resolution(video_path: str | Path) -> tuple[int, int]:
    """Get video width and height as displayed (rotation applied)."""
    info = probe_video(video_path)
    return info.width, info.height


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


@lru_cache(maxsize=1)
def _has_videotoolbox() -> bool:
    """Whether this Mac's ffmpeg exposes the hardware H.264 encoder."""
    try:
        out = subprocess.run(
            [FFMPEG, "-hide_banner", "-encoders"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return False
    return "h264_videotoolbox" in out


def video_encoder_args(width: int, height: int) -> list[str]:
    """Hardware encoder where there is one, x264 otherwise.

    VideoToolbox has no CRF, so quality is bought with a generous
    resolution-scaled bitrate instead of a rate factor.
    """
    if not _has_videotoolbox():
        return ["-c:v", "libx264", "-preset", "fast", "-crf", "18"]

    pixels = max(width * height, 1)
    if pixels <= 1280 * 720:
        mbit = 8
    elif pixels <= 1920 * 1080:
        mbit = 14
    elif pixels <= 2560 * 1440:
        mbit = 24
    else:
        mbit = 45
    return [
        "-c:v",
        "h264_videotoolbox",
        "-b:v",
        f"{mbit}M",
        "-maxrate",
        f"{mbit * 2}M",
        "-bufsize",
        f"{mbit * 2}M",
    ]


def audio_encoder_args(audio_codec: str | None) -> list[str]:
    """Copy the audio when the container will take it, re-encode when not."""
    if audio_codec is None:
        return ["-an"]
    if audio_codec in MP4_AUDIO_CODECS:
        return ["-c:a", "copy"]
    return ["-c:a", "aac", "-b:a", "192k"]


# Written for every delivery file: without yuv420p a 10-bit HEVC or ProRes
# source produces an mp4 that social platforms reject and half the players
# refuse; faststart is what lets one play before it has finished downloading.
DELIVERY_ARGS = ["-pix_fmt", "yuv420p", "-movflags", "+faststart"]


def _parse_progress_seconds(line: str) -> float | None:
    """Seconds encoded so far, from an ffmpeg `time=HH:MM:SS.xx` line."""
    try:
        time_str = line.split("time=")[1].split(" ")[0]
        hours, minutes, seconds = time_str.split(":")
        return float(hours) * 3600 + float(minutes) * 60 + float(seconds)
    except (IndexError, ValueError):
        return None


def run_ffmpeg(cmd: list[str], progress_callback: Callable[[float], None] | None = None) -> None:
    """Run ffmpeg to completion, always draining stderr.

    Draining is not optional. ffmpeg writes its banner and continuous stats
    to stderr; leave the pipe unread and it blocks once the buffer fills,
    which deadlocks the whole render a few minutes in. The tail is kept so
    a failure can report ffmpeg's own words instead of a bare exit code.
    """
    process = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )

    tail: deque[str] = deque(maxlen=_ERROR_TAIL_LINES)
    if process.stderr:
        for line in process.stderr:
            tail.append(line.rstrip())
            if progress_callback and "time=" in line:
                seconds = _parse_progress_seconds(line)
                if seconds is not None:
                    progress_callback(seconds)

    if process.wait() != 0:
        detail = "\n".join(tail).strip()
        message = f"FFmpeg failed with return code {process.returncode}"
        raise RuntimeError(f"{message}:\n{detail}" if detail else message)


def extract_audio(video_path: str | Path) -> Path:
    """Extract audio from video as WAV file in a temp directory."""
    tmp = Path(tempfile.mkdtemp(prefix="piko_"))
    audio_path = tmp / "audio.wav"

    cmd = [
        FFMPEG,
        "-nostdin",
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
    run_ffmpeg(cmd)
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
    info = probe_video(video_path)

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
        "-nostdin",
        *inputs,
        *filter_args,
        *audio_encoder_args(info.audio_codec),
        *video_encoder_args(info.width, info.height),
        *DELIVERY_ARGS,
        "-y",
        str(output_path),
    ]
    run_ffmpeg(cmd, progress_callback)
