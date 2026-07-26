"""Model management commands — list / download / check ASR models."""

from __future__ import annotations

from ..core.memory import MODEL_PEAK_MB
from ..protocol import emit

# "speed" and "quality" are bench-measured tiers (bench/asr/README.md):
# parakeet@mlx-audio bf16 (0.32 s/min) is fastest; turbo@mlx-whisper
# (1.91 s/min) medium; large-v3-8bit (3.94 s/min) slowest. WER is a
# near-tie across all three (4.7-4.8%), hence "high" quality on all — the
# point is that parakeet's speed doesn't cost quality. ram_mb is the peak
# RSS estimate from core/memory.py's MODEL_PEAK_MB, not download size.
ASR_MODELS = [
    {
        "id": "mlx-community/parakeet-tdt-0.6b-v3",
        "name": "Parakeet TDT v3",
        "size_mb": 2300,
        "ram_mb": MODEL_PEAK_MB["mlx-community/parakeet-tdt-0.6b-v3"],
        "speed": "fast",
        "quality": "high",
    },
    {
        "id": "mlx-community/whisper-large-v3-turbo",
        "name": "Large V3 Turbo",
        "size_mb": 1500,
        "ram_mb": MODEL_PEAK_MB["mlx-community/whisper-large-v3-turbo"],
        "speed": "medium",
        "quality": "high",
    },
    {
        "id": "mlx-community/whisper-large-v3-mlx-8bit",
        "name": "Large V3 (8-bit)",
        "size_mb": 1600,
        "ram_mb": MODEL_PEAK_MB["mlx-community/whisper-large-v3-mlx-8bit"],
        "speed": "slow",
        "quality": "high",
    },
]


def handle_list_models(params: dict) -> None:
    """List available ASR models and their download status."""
    from huggingface_hub import scan_cache_dir

    models_info = [dict(m) for m in ASR_MODELS]

    try:
        cache_info = scan_cache_dir()
        downloaded_repos = {r.repo_id for r in cache_info.repos}
    except Exception:
        downloaded_repos = set()

    for m in models_info:
        m["downloaded"] = m["id"] in downloaded_repos

    emit({"type": "models", "models": models_info})


def handle_download_model(params: dict) -> None:
    """Download a transcription model from HuggingFace, reporting bytes and speed."""
    from ..core.downloads import Progress, download_model, format_bytes

    model_id = params["model"]
    # ASR_MODELS is a list of plain dicts, so the size needs narrowing.
    sizes = [m["size_mb"] for m in ASR_MODELS if m["id"] == model_id]
    expected = sizes[0] if sizes and isinstance(sizes[0], int) else 0
    emit(
        {
            "type": "progress",
            "stage": "downloading",
            "percent": 0,
            "message": f"Downloading {model_id}...",
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
                    f"{expected / 1000:.1f} GB · "
                    f"{format_bytes(progress.bytes_per_second)}/s"
                ),
                "downloaded_bytes": progress.downloaded,
                "bytes_per_second": round(progress.bytes_per_second),
            }
        )

    try:
        path = download_model(model_id, on_progress)
        emit(
            {
                "type": "progress",
                "stage": "downloading",
                "percent": 100,
                "message": "Download complete",
            }
        )
        emit({"type": "result", "success": True, "message": f"Model downloaded to {path}"})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": "DOWNLOAD_ERROR"})


def handle_delete_model(params: dict) -> None:
    """Delete a downloaded model's files from the HuggingFace cache.

    Works for any repo id, not just the ASR list — the summarizer tiers live in
    the same cache. Nothing else on the machine is touched: this removes the
    revisions of one repo and reports how much that freed.
    """
    from huggingface_hub import scan_cache_dir

    model_id = params["model"]
    try:
        cache_info = scan_cache_dir()
        revisions = [
            revision.commit_hash
            for repo in cache_info.repos
            if repo.repo_id == model_id
            for revision in repo.revisions
        ]
        if not revisions:
            emit(
                {
                    "type": "result",
                    "success": True,
                    "model": model_id,
                    "downloaded": False,
                    "message": "Model was not downloaded",
                }
            )
            return

        strategy = cache_info.delete_revisions(*revisions)
        freed = strategy.expected_freed_size_str
        strategy.execute()
        emit(
            {
                "type": "result",
                "success": True,
                "model": model_id,
                "downloaded": False,
                "message": f"Removed {model_id} — freed {freed}",
            }
        )
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": "DELETE_ERROR"})


def handle_check_model(params: dict) -> None:
    """Check if a specific model is downloaded."""
    from huggingface_hub import scan_cache_dir

    model_id = params["model"]
    try:
        cache_info = scan_cache_dir()
        downloaded = any(r.repo_id == model_id for r in cache_info.repos)
    except Exception:
        downloaded = False

    emit({"type": "result", "success": True, "downloaded": downloaded, "model": model_id})
