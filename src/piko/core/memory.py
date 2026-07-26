"""Pre-flight memory guardrail for model loading.

macOS-only by design (same assumption as the hardcoded ffmpeg paths in
media.py): available memory is read from /usr/bin/vm_stat.

The generic part is the `@requires_memory(estimator)` decorator — put it
on any function that loads a model (Whisper today, an LLM for the meeting
summary skill tomorrow) with an estimator that turns the call's arguments
into an expected peak-RAM figure. The check runs before the wrapped
function, so the model never starts loading when it clearly won't fit.

Why audio length matters for Whisper: mlx-whisper decodes in 30-second
windows, but it loads the *entire* file as a float32 16 kHz array
(~230 MB/hour) and computes the mel spectrogram over the whole of it
(~180 MB/hour for large-v3) before decoding starts. So peak RAM is a
fixed per-model cost plus a part linear in audio duration — a huge
recording can OOM even when the model alone would fit.
"""

from __future__ import annotations

import functools
import re
import subprocess
from collections.abc import Callable

VM_STAT = "/usr/bin/vm_stat"

# Conservative peak RSS while transcribing (weights + activations + runtime),
# not the download size from ASR_MODELS.
MODEL_PEAK_MB = {
    "mlx-community/whisper-large-v3-mlx-8bit": 3000,
    "mlx-community/whisper-large-v3-turbo": 2800,
    # Measured (/usr/bin/time -l) at ~1.2 GB despite mlx-audio's
    # from_pretrained loading an fp32 checkpoint before casting to bf16 —
    # MLX's lazy evaluation never materializes both copies at once.
    "mlx-community/parakeet-tdt-0.6b-v3": 1500,
}
DEFAULT_MODEL_PEAK_MB = 3000

# Whole-file float32 audio + mel spectrogram + working copies.
AUDIO_MB_PER_HOUR = 600
SYSTEM_HEADROOM_MB = 512


class InsufficientMemoryError(RuntimeError):
    """Transcription would likely not fit in currently available memory."""


def parse_vm_stat(text: str) -> int | None:
    """Available bytes from vm_stat output: (free + inactive) * page size.

    Deliberately excludes speculative and purgeable pages (purgeable
    overlaps the active/inactive counts), so the figure is conservative.
    """
    page_match = re.search(r"page size of (\d+) bytes", text)
    if not page_match:
        return None
    page_size = int(page_match.group(1))

    pages = 0
    for name in ("Pages free", "Pages inactive"):
        match = re.search(rf"{name}:\s+(\d+)", text)
        if not match:
            return None
        pages += int(match.group(1))
    return pages * page_size


def available_memory_mb() -> int | None:
    """Currently available memory in MB, or None if it cannot be determined."""
    try:
        out = subprocess.run(
            [VM_STAT], capture_output=True, text=True, check=True, timeout=5
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    available = parse_vm_stat(out)
    return None if available is None else available // (1024 * 1024)


def estimate_transcribe_peak_mb(model: str, duration_s: float) -> int:
    """Estimated peak RAM for transcribing `duration_s` seconds with `model`."""
    model_mb = MODEL_PEAK_MB.get(model, DEFAULT_MODEL_PEAK_MB)
    audio_mb = int(duration_s / 3600 * AUDIO_MB_PER_HOUR)
    return model_mb + audio_mb


def check_memory(needed_mb: float, what: str) -> None:
    """Raise InsufficientMemoryError if `needed_mb` (+ headroom) won't fit.

    Fails open: if available memory cannot be determined, the check is
    skipped rather than blocking an operation that might succeed.
    """
    available = available_memory_mb()
    if available is None:
        return
    needed = int(needed_mb) + SYSTEM_HEADROOM_MB
    if available < needed:
        raise InsufficientMemoryError(
            f"Not enough free memory for {what}: ~{needed} MB needed, "
            f"~{available} MB available. Close other apps or pick a smaller model."
        )


def requires_memory[**P, R](
    estimator: Callable[P, tuple[float, str]],
) -> Callable[[Callable[P, R]], Callable[P, R]]:
    """Guard a model-loading function with a pre-flight memory check.

    `estimator` receives the exact arguments of the wrapped call and returns
    (estimated peak MB, human-readable description of what is being loaded).
    Raises InsufficientMemoryError before the wrapped function runs — i.e.
    before any weights are loaded.

        @requires_memory(lambda prompt, model="qwen": (LLM_PEAK_MB[model], model))
        def generate(prompt, model="qwen"): ...
    """

    def decorator(fn: Callable[P, R]) -> Callable[P, R]:
        @functools.wraps(fn)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            needed_mb, what = estimator(*args, **kwargs)
            check_memory(needed_mb, what)
            return fn(*args, **kwargs)

        return wrapper

    return decorator
