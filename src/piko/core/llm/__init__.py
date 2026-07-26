"""LLM capability shared by skills — one seam, several providers.

Skills import from here and never from a backend module:

    from ..core.llm import open_session

    with open_session({"tier": "balanced"}) as llm:
        summary = llm.generate_json(messages, SCHEMA)

Which model that is lives in `registry.py`; which provider runs it is decided
by `session.open_session`. See docs/ARCHITECTURE.md, "Model runtime".
"""

from __future__ import annotations

from .registry import TIERS, available_tiers, default_tier, resolve_tier
from .sampling import CONTROLS, SamplingParams, controls_payload
from .session import LLMSession, extract_json, open_session
from .types import (
    GenerationChunk,
    GenerationResult,
    LLMError,
    Message,
    ModelSpec,
    ProviderUnavailableError,
    StructuredOutputError,
)

__all__ = [
    "CONTROLS",
    "TIERS",
    "GenerationChunk",
    "GenerationResult",
    "LLMError",
    "LLMSession",
    "Message",
    "ModelSpec",
    "ProviderUnavailableError",
    "SamplingParams",
    "StructuredOutputError",
    "available_tiers",
    "controls_payload",
    "default_tier",
    "extract_json",
    "open_session",
    "resolve_tier",
]
