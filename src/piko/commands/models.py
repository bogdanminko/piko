"""Model management commands — list / download / check the models Piko runs.

Two kinds, and the difference is not cosmetic. An ASR model is *required* and
mutually exclusive: exactly one transcribes. The speaker model is optional and
additive: it runs after transcription, on the far-end track, and everything
works without it. `kind` is what lets the Models screen render the second as a
switch rather than as a fourth radio button.
"""

from __future__ import annotations

from ..core.memory import MODEL_WEIGHTS_MB
from ..protocol import emit

# "speed" and "quality" are bench-measured tiers (bench/asr/README.md):
# parakeet@mlx-audio bf16 (0.32 s/min) is fastest; turbo@mlx-whisper
# (1.91 s/min) medium; large-v3-8bit (3.94 s/min) slowest. WER is a
# near-tie across all three (4.7-4.8%), hence "high" quality on all — the
# point is that parakeet's speed doesn't cost quality. ram_mb is the measured
# weight of the loaded model (core/memory.py's MODEL_WEIGHTS_MB) — not the
# download size, and not the OOM guardrail's worst case.
ASR_MODELS = [
    {
        "id": "mlx-community/parakeet-tdt-0.6b-v3",
        "name": "Parakeet TDT v3",
        "size_mb": 2300,
        "ram_mb": MODEL_WEIGHTS_MB["mlx-community/parakeet-tdt-0.6b-v3"],
        "speed": "fast",
        "quality": "high",
        "kind": "asr",
    },
    {
        "id": "mlx-community/whisper-large-v3-turbo",
        "name": "Large V3 Turbo",
        "size_mb": 1500,
        "ram_mb": MODEL_WEIGHTS_MB["mlx-community/whisper-large-v3-turbo"],
        "speed": "medium",
        "quality": "high",
        "kind": "asr",
    },
    {
        "id": "mlx-community/whisper-large-v3-mlx-8bit",
        "name": "Large V3 (8-bit)",
        "size_mb": 1600,
        "ram_mb": MODEL_WEIGHTS_MB["mlx-community/whisper-large-v3-mlx-8bit"],
        "speed": "slow",
        "quality": "high",
        "kind": "asr",
    },
]

# Optional, and only ever one: telling the far-end voices apart. NVIDIA's
# Sortformer via mlx-audio — end-to-end, language-agnostic, up to four speakers.
# "quality" is deliberately not "high": four is a hard architectural ceiling
# (the output head is a Linear to exactly 4 units), and a fifth participant is
# folded into one of the four rather than reported.
SPEAKER_MODELS = [
    {
        "id": "mlx-community/diar_sortformer_4spk-v1-fp16",
        "name": "Sortformer 4-speaker",
        "size_mb": 236,
        "ram_mb": MODEL_WEIGHTS_MB["mlx-community/diar_sortformer_4spk-v1-fp16"],
        "speed": "fast",
        "quality": "up to 4 voices",
        "kind": "speakers",
    },
]

ALL_MODELS = ASR_MODELS + SPEAKER_MODELS


def handle_list_models(params: dict) -> None:
    """List every model Piko can run — both kinds — and what is on disk."""
    from huggingface_hub import scan_cache_dir

    models_info = [dict(m) for m in ALL_MODELS]

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
    # The registries are lists of plain dicts, so the size needs narrowing.
    sizes = [m["size_mb"] for m in ALL_MODELS if m["id"] == model_id]
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
