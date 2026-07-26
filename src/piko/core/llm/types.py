"""Types shared by every LLM provider.

Nothing here may import a provider SDK: these types are the vocabulary the
skills speak, and they have to stay meaningful whether the tokens come from
MLX on this machine or from an OpenAI-compatible server across the network.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, TypedDict

Role = Literal["system", "user", "assistant"]


class Message(TypedDict):
    """One chat turn. The only prompt format every provider understands."""

    role: Role
    content: str


@dataclass(frozen=True, slots=True)
class ModelSpec:
    """A concrete local model behind a tier name.

    The protocol never carries these fields — Swift asks for `fast` /
    `balanced` / `quality` and this is where that resolves, in one place
    (see docs/ARCHITECTURE.md, "Model runtime").
    """

    tier: str
    repo: str
    name: str
    size_mb: int
    """Download size, for the UI."""
    ram_mb: int
    """Measured peak RSS while generating — feeds core.memory's guard."""
    min_ram_mb: int
    """Total machine RAM below which this tier is not offered."""
    context_tokens: int


@dataclass(frozen=True, slots=True)
class GenerationChunk:
    """One streamed step: the new text plus counters valid at that point.

    The terminal fields are populated only on the last chunk (`done=True`),
    which is how `LLMSession.generate` recovers the full statistics without a
    second channel back from the provider.
    """

    text: str
    prompt_tokens: int
    generation_tokens: int
    done: bool = False
    finish_reason: str | None = None
    prompt_tps: float | None = None
    generation_tps: float | None = None
    peak_memory_mb: float | None = None


@dataclass(frozen=True, slots=True)
class GenerationResult:
    """A finished generation.

    Throughput fields are None for providers that do not report them (a remote
    server times its own hardware, not ours, so the numbers would mislead).
    """

    text: str
    prompt_tokens: int
    generation_tokens: int
    finish_reason: str | None = None
    prompt_tps: float | None = None
    generation_tps: float | None = None
    peak_memory_mb: float | None = None


class LLMError(RuntimeError):
    """Base for every failure this package raises."""


class ProviderUnavailableError(LLMError):
    """The backend could not be reached or is not configured."""


class StructuredOutputError(LLMError):
    """The model did not return JSON matching the requested shape."""
