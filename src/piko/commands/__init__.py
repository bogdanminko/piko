"""JSON command handlers — one module per protocol area.

Every handler takes the `params` dict from the incoming command and
emits protocol messages via piko.protocol.emit.
"""

from __future__ import annotations

from .models import handle_check_model, handle_download_model, handle_list_models
from .previews import handle_style_previews
from .render import handle_process, handle_render
from .transcribe import handle_transcribe

HANDLERS = {
    "process": handle_process,
    "transcribe": handle_transcribe,
    "render": handle_render,
    "style_previews": handle_style_previews,
    "list_models": handle_list_models,
    "download_model": handle_download_model,
    "check_model": handle_check_model,
}
