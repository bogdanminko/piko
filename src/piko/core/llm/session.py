"""The seam every LLM provider implements, and the factory that picks one.

A session owns whatever is expensive to set up — for the embedded backend that
is several gigabytes of weights and ~2 s of load time — and stays callable.
Skills are written against `LLMSession`, so the summary pass (one session, many
chunks) and a future agent (one session, many turns) share the same object and
neither knows which provider is underneath.

Adding a provider is one entry in `_BACKENDS` plus a module implementing
`stream`; nothing else in the codebase changes.
"""

from __future__ import annotations

import json
import re
from abc import ABC, abstractmethod
from collections.abc import Callable, Iterator, Sequence
from typing import Any

from .sampling import SamplingParams
from .types import (
    GenerationChunk,
    GenerationResult,
    LLMError,
    Message,
    StructuredOutputError,
)

# Temperature for a structured-output retry. Repeating a greedy decode would
# reproduce the same malformed reply verbatim, so the second attempt must
# sample — but only just enough to break the tie.
RETRY_TEMPERATURE = 0.4

# Models that ignore the instruction and wrap JSON in prose or a fenced block
# are common enough at 2B that unwrapping is the caller's default, not a
# fallback. Matches ```json ... ``` and bare ``` ... ```.
_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)

# A reasoning model answers *after* its reasoning, behind a marker: Qwen closes
# the block with </think>, harmony (GPT-OSS) opens the answer with a final
# channel. Everything before it is not the answer, and it is full of braces —
# the model drafts the very JSON it is about to write, and quotes the input.
# Measured on GPT-OSS 20B, that reliably turned a correct final answer into a
# parse failure, which the caller then reports as "the model returned nothing".
# Reasoning is disabled where a template allows it (mlx_backend.py); this is for
# the models and providers where it cannot be.
_REASONING_ENDS = ("</think>", "<|channel|>final<|message|>")

#: How a reply announces that what follows is reasoning rather than the answer.
#: Only text that opens with one of these is held back — a model that does not
#: reason must not be buffered waiting for an end marker that never comes.
REASONING_STARTS = ("<think>", "<|channel|>analysis", "<|start|>assistant<|channel|>analysis")
REASONING_ENDS = _REASONING_ENDS


class LLMSession(ABC):
    """One configured, ready-to-use model.

    Not thread-safe: a session wraps a single decode loop. Hold one per
    concurrent job, or serialize calls.
    """

    #: Human-readable, for logs and error messages ("Qwen3.5 4B", "ollama/…").
    description: str = "llm"

    @abstractmethod
    def stream(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
        reuse_cache: bool = False,
    ) -> Iterator[GenerationChunk]:
        """Yield chunks as they are produced; the last one has `done=True`.

        `sampling` defaults to greedy decoding (see sampling.py). `json_schema`
        asks for an object matching that schema; providers enforce it as
        strongly as they can — constrained decoding where the backend supports
        it, prompt instruction where it does not — so a caller must still
        validate. `generate_json` does that for you.

        `reuse_cache` keeps the KV cache between calls and re-uses however much
        of it the new prompt still agrees with. Opt-in, and only correct where
        consecutive calls really do share a prefix: a conversation does, the
        chunks of a transcript do not. Providers without a cache to keep ignore
        it.
        """

    def generate(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
        on_progress: Callable[[GenerationChunk], None] | None = None,
    ) -> GenerationResult:
        """Run `stream` to completion and collect the text plus statistics."""
        parts: list[str] = []
        last: GenerationChunk | None = None
        for chunk in self.stream(
            messages,
            sampling=sampling,
            json_schema=json_schema,
            stop=stop,
        ):
            parts.append(chunk.text)
            last = chunk
            if on_progress is not None:
                on_progress(chunk)

        if last is None:
            raise LLMError(f"{self.description} produced no output")
        return GenerationResult(
            text="".join(parts),
            prompt_tokens=last.prompt_tokens,
            generation_tokens=last.generation_tokens,
            finish_reason=last.finish_reason,
            prompt_tps=last.prompt_tps,
            generation_tps=last.generation_tps,
            peak_memory_mb=last.peak_memory_mb,
        )

    def generate_batch(
        self,
        conversations: Sequence[Sequence[Message]],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        on_done: Callable[[int], None] | None = None,
    ) -> list[GenerationResult]:
        """Run several independent prompts, in order.

        The default is sequential — correct everywhere, including a remote
        provider where "batching" would just be N HTTP requests. Backends that
        can genuinely run one forward pass over many prompts override this;
        callers get the speedup without knowing which kind they hold.
        """
        results = []
        for index, conversation in enumerate(conversations):
            results.append(self.generate(conversation, sampling=sampling, json_schema=json_schema))
            if on_done is not None:
                on_done(index + 1)
        return results

    def generate_json(
        self,
        messages: Sequence[Message],
        schema: dict[str, Any],
        *,
        sampling: SamplingParams | None = None,
        retries: int = 1,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """Generate and parse a JSON object, retrying once on unparseable output.

        Retrying rather than failing is deliberate: the smallest tier drifts
        out of the requested shape often enough that one more attempt is
        cheaper than surfacing an error to the user, and far cheaper than
        re-running the whole map-reduce pass.
        """
        attempts = max(1, retries + 1)
        base = sampling or SamplingParams()
        last_text = ""
        for attempt in range(attempts):
            retry = base if attempt == 0 else base.with_temperature(RETRY_TEMPERATURE)
            result = self.generate(messages, sampling=retry, json_schema=schema, **kwargs)
            last_text = result.text
            parsed = extract_json(result.text)
            if parsed is not None:
                return parsed
        raise StructuredOutputError(
            f"{self.description} did not return a JSON object after {attempts} "
            f"attempt(s); last output began: {last_text[:200]!r}"
        )

    def close(self) -> None:  # noqa: B027 — optional by design, not forgotten
        """Release the model. Idempotent.

        Deliberately concrete and empty: a remote provider holds nothing to
        free, so forcing every backend to implement this would add empty
        overrides rather than catch a real mistake.
        """

    def __enter__(self) -> LLMSession:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


def _after_reasoning(text: str) -> str:
    """Drop everything up to the last reasoning marker, keeping the answer.

    Deliberately the *last* occurrence and applied for every marker: a model
    that reasons twice, or a harmony reply that also contains a </think>, must
    leave only what follows the final one.
    """
    for marker in _REASONING_ENDS:
        index = text.rfind(marker)
        if index >= 0:
            text = text[index + len(marker) :]
    return text


def extract_json(text: str) -> dict[str, Any] | None:
    """Best-effort: pull one JSON object out of a model's reply.

    Handles the shapes seen in bench/llm runs — a bare object, an object inside
    a ``` fence, an object with prose around it, and an object preceded by a
    reasoning block. Returns None when nothing parses, so callers can retry
    rather than guess.
    """
    body = _after_reasoning(text).strip()
    fenced = _FENCE.search(body)
    if fenced:
        body = fenced.group(1).strip()

    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(body[start : end + 1])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _open_mlx(params: dict) -> LLMSession:
    from .mlx_backend import MLXSession  # heavy import, only when actually used

    return MLXSession.from_params(params)


def _open_openai(params: dict) -> LLMSession:
    from .openai_backend import OpenAICompatibleSession

    return OpenAICompatibleSession.from_params(params)


#: provider name → opener. The whole extension point for Ollama / LM Studio /
#: OpenAI / anything else speaking the same wire format is `openai`, which
#: takes a base_url — one URL field, not a provider system (ARCHITECTURE.md).
_BACKENDS: dict[str, Callable[[dict], LLMSession]] = {
    "mlx": _open_mlx,
    "openai": _open_openai,
}

DEFAULT_PROVIDER = "mlx"


def open_session(params: dict | None = None) -> LLMSession:
    """Build a session from protocol params.

    `{"provider": "mlx", "tier": "balanced"}` (the default) or
    `{"provider": "openai", "base_url": ..., "model": ..., "api_key": ...}`.
    """
    params = params or {}
    provider = params.get("provider") or DEFAULT_PROVIDER
    opener = _BACKENDS.get(provider)
    if opener is None:
        known = ", ".join(sorted(_BACKENDS))
        raise LLMError(f"Unknown LLM provider {provider!r} (known: {known})")
    return opener(params)
