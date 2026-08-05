"""Tier → model registry: the single place a tier name becomes a repo id.

docs/ARCHITECTURE.md makes this a hard rule — the Swift UI and the JSON
protocol only ever speak a tier name, so swapping a tier's underlying model
never touches the frontend.

Picks come from bench/llm (Qwen3.5-4B at 4-bit, measured on an M4 Max):
`balanced` is the default because it runs comfortably on 16 GB while beating
the smaller tier on every quality axis, and `quality` (dense 9B) is the opt-in
above it — still inside 16 GB, with little room beside it.

**Nothing larger than 9B, on purpose.** The ladder briefly had a fourth rung
and both candidates for it argued against themselves. GPT-OSS 20B was the only
model here from another family and charged for that everywhere: harmony prompt
format instead of Qwen's template, `reasoning_effort` instead of
`enable_thinking` with no "off" at all, and an analysis channel emitted into
the *text* stream — choosing that tier put `<|channel|>analysis<|message|>…`
verbatim into the chat bubble. Qwen3.6-35B-A3B replaced it and then failed the
only test that matters: 20.4 GB of weights, and on a 36 GB Mac with an ordinary
desktop open the pre-flight check finds ~14 GB free and refuses. A tier that is
offered and then declines to load is worse than one that was never offered.

What the app actually asks a model to do — extract action items from transcript
chunks, write a summary, answer a short question about what is on screen — is
not where the last few points of reasoning benchmark are won. It is where
throughput over nine chunks and fitting in memory are won. Three tiers, all
Qwen, none of them a download somebody regrets.
"""

from __future__ import annotations

from ..memory import total_memory_mb
from .types import ModelSpec

# ram_mb is the measured peak of a real summarization, not download size, and
# it is what `check_memory` refuses a load against — so it has to describe the
# job the app actually runs.
#
# Method, one tier per fresh process: open an `MLXSession` and call its
# `generate_batch` with eight full `CHUNK_CHARS` chunks of Russian (~2600
# tokens each — the same character budget in English is ~1600, so this is the
# expensive end of what a chunk can be) at the default `max_tokens`. That is
# the map phase of a meeting summary, verbatim.
#
# Read from `mx.get_peak_memory()`, **not** from RSS. That is the correction
# these numbers carry: getrusage does not see Metal's buffers at all, and the
# figures it produced were 25-35% low — on the 9B tier it reported 5.54 GB for
# a job whose real peak is 7.13 GB. A guard calibrated on a number that cannot
# see most of the allocation is a guard that lets the machine start swapping.
#
# Weights are roughly two thirds of each figure; the rest is prefill
# activations and the KV cache, which is why weights are the wrong thing to
# quote for an LLM. The prefill share used to be far larger — see
# `PREFILL_STEP_SIZE` in mlx_backend.py for the 5 GB that came off the 9B tier.
TIERS: dict[str, ModelSpec] = {
    "fast": ModelSpec(
        tier="fast",
        repo="mlx-community/Qwen3.5-2B-4bit",
        name="Qwen3.5 2B",
        size_mb=1750,
        ram_mb=2600,  # measured: 2.52 GB peak, of which 0.99 GB weights
        min_ram_mb=8192,
        context_tokens=262144,
    ),
    "balanced": ModelSpec(
        tier="balanced",
        repo="mlx-community/Qwen3.5-4B-4bit",
        name="Qwen3.5 4B",
        size_mb=3060,
        ram_mb=4800,  # measured: 4.66 GB peak, of which 2.20 GB weights
        min_ram_mb=16384,
        context_tokens=262144,
    ),
    "quality": ModelSpec(
        tier="quality",
        repo="mlx-community/Qwen3.5-9B-4bit",
        name="Qwen3.5 9B",
        size_mb=5980,
        ram_mb=7300,  # measured: 7.13 GB peak, of which 4.69 GB weights
        # Left at 16384 deliberately, now that ram_mb is honest. 7.3 GB is a
        # tier a 16 GB Mac can run with the browser shut and cannot run with
        # forty tabs open — which is a question about this minute, not about
        # the machine, and `check_memory` is the thing that answers it. The
        # picker greys a tier out rather than hiding it, so the requirement is
        # readable either way.
        min_ram_mb=16384,
        context_tokens=262144,
    ),
}

DEFAULT_TIER = "balanced"

# Machines below `balanced`'s bar still get a working product, just a smaller
# model — never a broken one.
FALLBACK_TIER = "fast"


def available_tiers() -> list[ModelSpec]:
    """Tiers this machine has enough total RAM to run, largest last."""
    total = total_memory_mb()
    specs = sorted(TIERS.values(), key=lambda s: s.min_ram_mb)
    if total is None:
        return specs
    fits = [s for s in specs if s.min_ram_mb <= total]
    # Never hand back an empty picker: the smallest tier is always offered.
    return fits or specs[:1]


def default_tier() -> str:
    """`balanced` where it fits, otherwise the largest tier that does."""
    usable = {s.tier for s in available_tiers()}
    if DEFAULT_TIER in usable:
        return DEFAULT_TIER
    return available_tiers()[-1].tier if usable else FALLBACK_TIER


def resolve_tier(tier: str | None) -> ModelSpec:
    """Tier name → ModelSpec. Unknown or missing names fall back to the default.

    Deliberately forgiving: a stale tier name in the UI's saved state must not
    break a run, and the protocol carries no other way to name a model.
    """
    if tier and tier in TIERS:
        return TIERS[tier]
    return TIERS[default_tier()]
