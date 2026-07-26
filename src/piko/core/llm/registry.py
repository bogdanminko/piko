"""Tier → model registry: the single place a tier name becomes a repo id.

docs/ARCHITECTURE.md makes this a hard rule — the Swift UI and the JSON
protocol only ever speak a tier name, so swapping a tier's underlying model
never touches the frontend.

Picks come from bench/llm (Qwen3.5-4B at 4-bit, measured on an M4 Max):
`balanced` is the default because it runs comfortably on 16 GB while beating
the smaller tier on every quality axis. The two tiers above it are opt-in:
`quality` (dense 9B) still fits 16 GB but leaves little room beside it, and
`max` (20B MoE) does not fit PRODUCT.md's "comfortably on a 16 GB Mac" bar at
all. Note this is four tiers where PRODUCT.md describes three — the ladder grew
a rung and the doc has not caught up.
"""

from __future__ import annotations

from ..memory import total_memory_mb
from .types import ModelSpec

# ram_mb is peak RSS, not download size. Only the `balanced` row is measured
# (bench/llm/results — 4.3 GB peak on a 21k-token prompt); the other two are
# extrapolated from it by weight-size delta and are marked below. Re-measure
# before trusting them in a memory-tight decision.
TIERS: dict[str, ModelSpec] = {
    "fast": ModelSpec(
        tier="fast",
        repo="mlx-community/Qwen3.5-2B-4bit",
        name="Qwen3.5 2B",
        size_mb=1750,
        ram_mb=3300,  # estimated: ~1.2 GB weights + the ~1.9 GB runtime overhead measured at 4B
        min_ram_mb=8192,
        context_tokens=262144,
    ),
    "balanced": ModelSpec(
        tier="balanced",
        repo="mlx-community/Qwen3.5-4B-4bit",
        name="Qwen3.5 4B",
        size_mb=3060,
        ram_mb=4400,  # measured: 4.32 GB peak at 21k prompt tokens
        min_ram_mb=16384,
        context_tokens=262144,
    ),
    "quality": ModelSpec(
        tier="quality",
        repo="mlx-community/Qwen3.5-9B-4bit",
        name="Qwen3.5 9B",
        size_mb=5980,
        ram_mb=7800,  # estimated: ~4.6 GB weights + the runtime overhead measured at 4B
        min_ram_mb=16384,
        context_tokens=262144,
    ),
    "max": ModelSpec(
        tier="max",
        repo="mlx-community/gpt-oss-20b-MXFP4-Q8",
        name="GPT-OSS 20B",
        size_mb=12100,
        ram_mb=14500,  # estimated from weight size; never measured
        min_ram_mb=24576,
        context_tokens=131072,
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
