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
SYSCTL = "/usr/sbin/sysctl"

# What a model actually occupies once loaded, measured (mx.get_active_memory,
# each model in a fresh process, loaded through the exact call the product
# uses — bf16 for parakeet via Model.from_pretrained, fp16 for whisper via
# ModelHolder). This is the number the Models screen shows, because "will this
# fit on my Mac" is a question about the model, not about our worst case.
#
# Keep the two dicts apart. Showing MODEL_PEAK_MB was telling people Turbo
# needs 2.8 GB when its weights are 1.6 GB — the difference between "won't fit
# in 8 GB" and "fine", decided by a number that was never about the model.
MODEL_WEIGHTS_MB = {
    "mlx-community/whisper-large-v3-mlx-8bit": 1720,
    "mlx-community/whisper-large-v3-turbo": 1614,
    "mlx-community/parakeet-tdt-0.6b-v3": 1296,
    "mlx-community/diar_sortformer_4spk-v1-fp16": 248,
}

# Conservative peak while transcribing (weights + activations + runtime). Used
# only by check_memory to refuse a job that would not fit — never displayed.
# Measured on 5 minutes of audio, same load paths; erring high is correct here,
# since the cost of being wrong is an OOM rather than an ugly label.
MODEL_PEAK_MB = {
    # Loading alone grew RSS by 3.6 GB — the dequantizing load path is the
    # expensive part here, and 32 s of it. Raised from 3000 on that evidence.
    "mlx-community/whisper-large-v3-mlx-8bit": 3600,
    # Measured 1.9 GB RSS transcribing 5 minutes; 2800 was a guess.
    "mlx-community/whisper-large-v3-turbo": 2200,
    # Measured 1.26 GB RSS transcribing 5 minutes, despite mlx-audio's
    # from_pretrained loading an fp32 checkpoint before casting to bf16 —
    # MLX's lazy evaluation never materializes both copies at once. The public
    # `stt.load()` would keep fp32 and cost 2.5 GB; core/parakeet_transcriber.py
    # deliberately does not use it.
    "mlx-community/parakeet-tdt-0.6b-v3": 1500,
    # The odd one out: a *marginal* cost, not a standalone one. Diarization only
    # ever runs in the same process straight after transcription, so MLX and
    # Metal are already up and the ~600 MB they cost is already on the bill.
    # Measured that way (getrusage, parakeet loaded and used first): +279 MB for
    # a 5-minute call. Measured alone it looks like 750 MB, but that number
    # charges this model for the runtime the transcriber already paid for.
    #
    # Quantizing would not move it. A 4-bit build has a quarter of the weights
    # (88 MB active vs 248 MB) and loads into the *same* RSS, because the cost
    # is the loading path, not the tensors. `skills/meeting/diarize.py` records
    # the rest of that finding.
    "mlx-community/diar_sortformer_4spk-v1-fp16": 300,
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


def total_memory_mb() -> int | None:
    """Physical RAM installed in MB, or None if it cannot be determined.

    Used to decide which model *tiers* to offer at all (a 20B tier makes no
    sense on a 16 GB machine), which is a different question from
    `available_memory_mb`'s "does this fit right now".
    """
    try:
        out = subprocess.run(
            [SYSCTL, "-n", "hw.memsize"], capture_output=True, text=True, check=True, timeout=5
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return int(out.strip()) // (1024 * 1024)
    except ValueError:
        return None


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
