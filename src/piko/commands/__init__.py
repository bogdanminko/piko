"""JSON command handlers — one module per protocol area.

Every handler takes the `params` dict from the incoming command and
emits protocol messages via piko.protocol.emit.
"""

from __future__ import annotations

from .broll_pack import handle_download_broll_pack, handle_fetch_broll, handle_search_broll
from .chat import handle_chat
from .llm import (
    handle_download_llm_model,
    handle_list_llm_tiers,
    handle_llm_status,
    handle_release_llm,
    handle_warmup_llm,
)
from .meeting import (
    handle_finalize_recording,
    handle_import_recording,
    handle_summarize_meeting,
    handle_transcribe_meeting,
)
from .models import (
    handle_check_model,
    handle_delete_model,
    handle_download_model,
    handle_list_models,
)
from .previews import handle_style_previews
from .render import handle_process, handle_render
from .transcribe import handle_transcribe

HANDLERS = {
    "process": handle_process,
    "chat": handle_chat,
    "transcribe": handle_transcribe,
    "finalize_recording": handle_finalize_recording,
    "import_recording": handle_import_recording,
    "transcribe_meeting": handle_transcribe_meeting,
    "summarize_meeting": handle_summarize_meeting,
    "render": handle_render,
    "style_previews": handle_style_previews,
    "list_models": handle_list_models,
    "download_model": handle_download_model,
    "check_model": handle_check_model,
    "delete_model": handle_delete_model,
    "download_broll_pack": handle_download_broll_pack,
    "fetch_broll": handle_fetch_broll,
    "search_broll": handle_search_broll,
    "list_llm_tiers": handle_list_llm_tiers,
    "download_llm_model": handle_download_llm_model,
    "warmup_llm": handle_warmup_llm,
    "llm_status": handle_llm_status,
    "release_llm": handle_release_llm,
}
