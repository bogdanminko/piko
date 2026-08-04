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

# ram_mb is measured peak RSS while summarizing, not download size — every row
# below, on a 28k-token prompt (longer than a real meeting, so the figure has
# headroom rather than needing it). Method: load through `mlx_lm.load()`, the
# same call mlx_backend.py makes, one model per fresh process, RSS read from
# getrusage. Resident weights alone are roughly half of each figure; the rest is
# the KV cache the prompt forces, which is why weights are the wrong thing to
# quote for an LLM.
#
# These replace estimates that ran 40-70% high and, through min_ram_mb, decided
# whether a tier was offered at all.
TIERS: dict[str, ModelSpec] = {
    "fast": ModelSpec(
        tier="fast",
        repo="mlx-community/Qwen3.5-2B-4bit",
        name="Qwen3.5 2B",
        size_mb=1750,
        ram_mb=2000,  # measured: 1.98 GB peak RSS, of which 1.06 GB weights
        min_ram_mb=8192,
        context_tokens=262144,
    ),
    "balanced": ModelSpec(
        tier="balanced",
        repo="mlx-community/Qwen3.5-4B-4bit",
        name="Qwen3.5 4B",
        size_mb=3060,
        ram_mb=3300,  # measured: 3.26 GB peak RSS, of which 2.37 GB weights
        min_ram_mb=16384,
        context_tokens=262144,
    ),
    "quality": ModelSpec(
        tier="quality",
        repo="mlx-community/Qwen3.5-9B-4bit",
        name="Qwen3.5 9B",
        size_mb=5980,
        ram_mb=6000,  # measured: 5.96 GB peak RSS, of which 5.04 GB weights
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
