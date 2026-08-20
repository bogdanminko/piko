"""Parakeet TDT transcription via mlx-audio (bf16).

Loaded through mlx-audio's internal `Model.from_pretrained(dtype=bf16)`
rather than its public `load_model()` (which keeps the checkpoint's fp32
dtype) — bench-confirmed as both faster and lighter, see
bench/asr/README.md. Chunking (120s / 15s overlap) is mandatory: an
unchunked pass on long audio OOMs Metal.

Parakeet produces no per-word confidence, unlike Whisper — words carry
only `word`/`start`/`end`. Downstream keyword detection already treats a
missing `probability` as 0 (see keyword_detector.py), so it degrades from
2-of-3 prosody signals to 2-of-2 automatically.
"""

from __future__ import annotations

import subprocess
from collections.abc import Callable

from .media import get_video_duration
from .memory import estimate_transcribe_peak_mb, requires_memory

CHUNK_DURATION_S = 120.0
OVERLAP_DURATION_S = 15.0


def _tokens_to_words(tokens: list) -> list[dict]:
    """Group mlx-audio's sub-word AlignedTokens into whole words.

    A token starts a new word when its decoded text begins with a space
    (SentencePiece's `▁` word-boundary marker, already converted to " " by
    mlx-audio's tokenizer.decode) — mirrors Whisper's own word/token text
    convention (leading space on every word but the first).
    """
    words: list[dict] = []
    current_text = ""
    current_start = 0.0
    current_end = 0.0
    for i, tok in enumerate(tokens):
        if (tok.text.startswith(" ") or i == 0) and current_text:
            words.append({"word": current_text, "start": current_start, "end": current_end})
            current_text = ""
        if not current_text:
            current_start = tok.start
        current_text += tok.text
        current_end = tok.end
    if current_text:
        words.append({"word": current_text, "start": current_start, "end": current_end})
    return words


def _transcribe_estimate(
    audio_path: str,
    model: str = "mlx-community/parakeet-tdt-0.6b-v3",
    language: str | None = None,
    progress_callback: Callable[[float], None] | None = None,
) -> tuple[float, str]:
    """Peak-RAM estimate for the transcribe() call below (same signature)."""
    try:
        duration = get_video_duration(audio_path)
    except (OSError, subprocess.SubprocessError, ValueError):
        duration = 0.0
    needed_mb = estimate_transcribe_peak_mb(model, duration)
    what = f"{model.rsplit('/', 1)[-1]} + {duration / 60:.0f} min of audio"
    return needed_mb, what


@requires_memory(_transcribe_estimate)
def transcribe(
    audio_path: str,
    model: str = "mlx-community/parakeet-tdt-0.6b-v3",
    language: str | None = None,
    progress_callback: Callable[[float], None] | None = None,
) -> dict:
    """Transcribe audio using Parakeet TDT via mlx-audio.

    Returns dict with keys: text, segments. Each segment contains words
    with: word, start, end (no `probability` — Parakeet has none).
    `language` is accepted for signature parity with the Whisper path but
    ignored: Parakeet infers language from audio and mlx-audio's result
    carries no language field.
    """
    import mlx.core as mx
    from mlx_audio.stt.models.parakeet.parakeet import Model

    parakeet_model = Model.from_pretrained(model, dtype=mx.bfloat16)
    mx.eval(parakeet_model.parameters())

    duration = get_video_duration(audio_path) if progress_callback else 0.0

    def on_chunk(position: float, total: float) -> None:
        if progress_callback is not None and total > 0:
            progress_callback(position / total * duration)

    result = parakeet_model.generate(
        audio_path,
        chunk_duration=CHUNK_DURATION_S,
        overlap_duration=OVERLAP_DURATION_S,
        chunk_callback=on_chunk if progress_callback else None,
    )

    segments = [
        {
            "start": sentence.start,
            "end": sentence.end,
            "text": sentence.text,
            "words": _tokens_to_words(sentence.tokens),
        }
        for sentence in result.sentences
    ]
    return {"text": result.text, "segments": segments}
