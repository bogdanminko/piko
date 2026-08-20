"""LLM lifecycle commands — pick a tier, warm it, check it, drop it.

These carry no generation of their own; they exist so the frontend can hide the
load cost. The intended sequence is: transcribe, fire `warmup_llm` while the
user reads the transcript, then summarize against already-resident weights.

`warmup_llm` is only meaningful when the backend is kept alive across commands
(one process, several stdin lines — see main.py). Under the one-shot contract
the process exits and the warm model dies with it, so the call is harmless but
pointless.
"""

from __future__ import annotations

from ..core.downloads import Progress, download_model, format_bytes
from ..core.llm import available_tiers, controls_payload, default_tier, pool, resolve_tier
from ..core.memory import total_memory_mb
from ..protocol import emit
from ..skills.meeting.summary import offered_languages


def _downloaded_repos() -> set[str]:
    try:
        from huggingface_hub import scan_cache_dir

        return {r.repo_id for r in scan_cache_dir().repos}
    except Exception:  # noqa: BLE001 — an unreadable cache only costs us a flag
        return set()


def handle_list_llm_tiers(params: dict) -> None:
    """Tiers this machine can run, with download state, for the model picker."""
    downloaded = _downloaded_repos()
    runnable = {spec.tier for spec in available_tiers()}
    total_mb = total_memory_mb()

    from ..core.llm import TIERS

    tiers = [
        {
            "id": spec.repo,
            "tier": spec.tier,
            "name": spec.name,
            "size_mb": spec.size_mb,
            "ram_mb": spec.ram_mb,
            "context_tokens": spec.context_tokens,
            "downloaded": spec.repo in downloaded,
            # False means "this Mac does not have the RAM" — the UI should show
            # it greyed with the requirement, not hide it.
            "available": spec.tier in runnable,
        }
        for spec in sorted(TIERS.values(), key=lambda s: s.min_ram_mb)
    ]
    # Sampling controls ship with the tiers so Settings renders its sliders
    # from the backend's ranges instead of hardcoding them (sampling.py).
    emit(
        {
            "type": "tiers",
            "tiers": tiers,
            "total_ram_mb": total_mb,
            # The frontend must not derive this itself. "Largest that fits" is
            # the wrong rule — `quality` is opt-in by design (PRODUCT.md), so
            # the pick belongs to registry.default_tier() alone.
            "default_tier": default_tier(),
            "sampling_controls": controls_payload(),
            # Offered here rather than hardcoded in Swift, for the same reason
            # the tiers are: one list, one place to change it.
            "languages": offered_languages(),
        }
    )


def handle_warmup_llm(params: dict) -> None:
    """Start loading the model in the background; return without waiting."""
    pool.warm_async(params)
    emit({"type": "result", "success": True, "llm": pool.status(params)})


def handle_llm_status(params: dict) -> None:
    """Is a model resident, is one loading, and does it match this request?"""
    emit({"type": "result", "success": True, "llm": pool.status(params)})


def handle_release_llm(params: dict) -> None:
    """Free the resident model — the memory-pressure escape hatch."""
    pool.release()
    emit({"type": "result", "success": True, "llm": pool.status(params)})


def handle_download_llm_model(params: dict) -> None:
    """Fetch a tier's weights so the first summary is not also a download.

    Reports bytes and speed throughout: the quality tier is 12 GB, and a bar
    that only says "Downloading..." for ten minutes is indistinguishable from
    one that has hung.
    """
    spec = resolve_tier(params.get("tier"))
    emit(
        {
            "type": "progress",
            "stage": "downloading",
            "percent": 0,
            "message": f"Downloading {spec.name}...",
        }
    )

    def on_progress(progress: Progress) -> None:
        emit(
            {
                "type": "progress",
                "stage": "verifying" if progress.finalizing else "downloading",
                "percent": round(progress.percent, 1),
                "message": (
                    f"Verifying {format_bytes(progress.downloaded)}..."
                    if progress.finalizing
                    else f"{format_bytes(progress.downloaded)} of "
                    f"{spec.size_mb / 1000:.1f} GB · "
                    f"{format_bytes(progress.bytes_per_second)}/s"
                ),
                "downloaded_bytes": progress.downloaded,
                "bytes_per_second": round(progress.bytes_per_second),
            }
        )

    try:
        download_model(spec.repo, on_progress)
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": "DOWNLOAD_ERROR"})
        return
    emit({"type": "result", "success": True, "model": spec.repo, "downloaded": True})
