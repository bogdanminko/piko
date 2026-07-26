"""Model management commands — list / download / check Whisper models."""

from __future__ import annotations

from ..protocol import emit

WHISPER_MODELS = [
    {"id": "mlx-community/whisper-large-v3-mlx-8bit", "name": "Large V3 (8-bit)", "size_mb": 1600},
    {"id": "mlx-community/whisper-large-v3-turbo", "name": "Large V3 Turbo", "size_mb": 1500},
    {"id": "mlx-community/whisper-large-v3-mlx-4bit", "name": "Large V3 (4-bit)", "size_mb": 900},
    {"id": "mlx-community/whisper-medium-mlx", "name": "Medium", "size_mb": 1500},
    {"id": "mlx-community/whisper-tiny", "name": "Tiny", "size_mb": 75},
]


def handle_list_models(params: dict) -> None:
    """List available Whisper models and their download status."""
    from huggingface_hub import scan_cache_dir

    models_info = [dict(m) for m in WHISPER_MODELS]

    try:
        cache_info = scan_cache_dir()
        downloaded_repos = {r.repo_id for r in cache_info.repos}
    except Exception:
        downloaded_repos = set()

    for m in models_info:
        m["downloaded"] = m["id"] in downloaded_repos

    emit({"type": "models", "models": models_info})


def handle_download_model(params: dict) -> None:
    """Download a Whisper model from HuggingFace."""
    from huggingface_hub import snapshot_download

    model_id = params["model"]
    emit(
        {
            "type": "progress",
            "stage": "downloading",
            "percent": 0,
            "message": f"Downloading {model_id}...",
        }
    )

    try:
        path = snapshot_download(repo_id=model_id)
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
