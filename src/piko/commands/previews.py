"""`style_previews` command — cached PNG strips for the style pickers."""

from __future__ import annotations

from ..cache import CACHE_DIR
from ..protocol import emit


def handle_style_previews(params: dict) -> None:
    """Render preview PNGs (sample subtitle on black) for every style."""
    from ..skills.captions.preview import generate_style_previews

    output_dir = params.get("output_dir") or str(CACHE_DIR / "previews")
    force = params.get("force", False)

    try:
        previews = generate_style_previews(output_dir, force=force)
        emit({"type": "result", "success": True, "previews": previews})
    except Exception as e:
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
