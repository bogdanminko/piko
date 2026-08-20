"""Who, among the people on the far end — Sortformer over the system track.

The two-track recording already answers "me or them" physically, without a
model (see `speakers.py`). What it cannot answer is which of *them*, because
everyone on the call arrives mixed down one output device. That is the only
question this module asks, and it asks it of the system track alone.

Running on the far-end track rather than the mix is deliberate and cheaper on
both counts: the microphone side is a fact, so re-deciding it with a model
could only make it worse, and a voice that is present on one track cannot be
clustered as a second participant on the other.

The model is NVIDIA's Sortformer v1, ported to MLX by mlx-audio — already a
dependency of this project, so diarization adds a download and no new runtime.
It resolves **up to four** far-end speakers; a fifth is folded into one of the
four rather than reported, which is why the transcript keeps the plain "them"
label whenever diarization declines to answer.

Failure here is never fatal: no model, no network, not enough memory — all of
them fall back to the side-only labels the recorder can always produce.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable
from dataclasses import dataclass

import numpy as np

from .audio import RAW_RATE

# fp16 (236 MB) rather than fp32 (494 MB): this is a segmentation head, not a
# generative model, and the halved download is worth more than the last decimal.
#
# Quantizing further is not the lever it looks like. Measured on a 4-bit build:
# the weights do shrink 4x (88 MB resident vs 248 MB), and process RSS after
# loading does not move at all — ~600 MB either way, because it is the load path
# and Metal init that cost, not the tensors. The one published 4-bit port
# (ekryski/diar_streaming_sortformer_4spk-v2.1-4bit) also cannot run: it
# quantizes the subsampling convolutions too, and mx.conv2d refuses a uint32
# weight. So: no int8, no 4-bit, for a saving that is not there.
MODEL_ID = "mlx-community/diar_sortformer_4spk-v1-fp16"

# Sortformer attends over the whole recording at once, so allocation grows with
# the square of its length. Measured with MLX's peak-allocation counter (which
# runs above real RSS, but is the right thing to compare the two paths with):
# 1.1 GB at 60 s, 1.3 GB at 130 s, 1.7 GB at 180 s, 2.7 GB at 300 s.
#
# The streaming path is flat by comparison — 0.95 GB whether the input is 130 s
# or 300 s — because it chunks the audio while threading one speaker cache
# through every chunk, which is also what keeps "Participant 2" in the last
# minute the same person as in the first. It is therefore cheaper than one-shot
# even at two minutes, and one-shot is kept only for short clips, where it is
# slightly better (no chunk boundaries) and the cost is small either way.
_ONE_SHOT_LIMIT = 120.0
_CHUNK_SECONDS = 10.0

# A speaker is active when the model says so with more than even odds.
_THRESHOLD = 0.5
# Below this a turn is a breath or a cross-talk artefact, not a contribution.
_MIN_TURN = 0.4
# Gaps shorter than this are the pauses inside one turn, not a handover.
_MERGE_GAP = 0.3


@dataclass(frozen=True)
class Turn:
    """One stretch of the far-end track owned by one voice."""

    start: float
    end: float
    speaker: int


def diarize(system: np.ndarray, rate: int = RAW_RATE) -> list[Turn]:
    """Split the far-end track into per-voice turns.

    Returns [] whenever the answer would be a guess — an empty track, a model
    that will not load, a machine that cannot run it. The caller keeps its
    side-only labels in that case, which are still true, just less specific.
    """
    if system.size == 0:
        return []

    duration = system.size / rate
    try:
        from mlx_audio.vad import load
    except ImportError:  # pragma: no cover - depends on the installed extras
        _warn("mlx-audio has no vad module; skipping diarization")
        return []

    turns: list[Turn] = []
    try:
        model = load(MODEL_ID)
        if duration <= _ONE_SHOT_LIMIT:
            outputs: Iterable = [
                model.generate(
                    system,
                    sample_rate=rate,
                    threshold=_THRESHOLD,
                    min_duration=_MIN_TURN,
                    merge_gap=_MERGE_GAP,
                )
            ]
        else:
            outputs = model.generate_stream(
                system,
                sample_rate=rate,
                chunk_duration=_CHUNK_SECONDS,
                threshold=_THRESHOLD,
                min_duration=_MIN_TURN,
                merge_gap=_MERGE_GAP,
            )

        # Consumed one chunk at a time and dropped immediately. Each output
        # carries the per-frame probabilities *and* the speaker cache it was
        # produced with; keeping the list would pin a hundred of those for a
        # long call, to read three floats out of each.
        for output in outputs:
            turns.extend(
                Turn(
                    start=float(segment.start),
                    end=float(segment.end),
                    speaker=int(segment.speaker),
                )
                for segment in output.segments
                if float(segment.end) > float(segment.start)
            )
    except Exception as e:  # noqa: BLE001 - a transcript must survive this
        _warn(f"diarization unavailable ({type(e).__name__}: {e})")
        return []

    turns.sort(key=lambda turn: turn.start)
    return turns


def renumber(turns: list[Turn]) -> dict[int, int]:
    """Model speaker index → 1-based number in order of first appearance.

    Sortformer numbers its four output slots by arrival, but leaves the unused
    ones empty; a call where slots 0 and 2 spoke would otherwise be presented
    as "Participant 1" and "Participant 3" with nobody in between.
    """
    order: dict[int, int] = {}
    for turn in turns:
        if turn.speaker not in order:
            order[turn.speaker] = len(order) + 1
    return order


def _warn(message: str) -> None:
    """stdout is the JSON protocol; anything human-readable goes to stderr."""
    sys.stderr.write(f"[piko] {message}\n")
