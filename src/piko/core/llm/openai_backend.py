"""OpenAI-compatible backend — rung 2 of the runtime ladder.

One `base_url` covers Ollama, LM Studio, llama.cpp's server, OpenAI itself and
anything else speaking the same wire format. That is deliberate: ARCHITECTURE.md
asks for "one URL field, not a provider system", so there are no per-vendor
branches here and adding a vendor means typing a different URL, not writing
code.

Uses the official `openai` SDK rather than hand-rolled HTTP: streaming chat
completions mean SSE framing, partial-chunk handling, retry policy and error
taxonomy, none of which are worth reimplementing or maintaining. (The stdlib
`urllib` used elsewhere in the backend downloads files — a much smaller job.)
"""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from typing import Any, cast

import openai
from openai import OpenAI, omit
from openai.types.chat import ChatCompletionMessageParam
from openai.types.shared_params import ResponseFormatJSONSchema

from .sampling import SamplingParams
from .session import LLMSession
from .types import GenerationChunk, LLMError, Message, ProviderUnavailableError

# Generous: a remote 70B on a cold queue is slow, and a spurious timeout costs
# the user the whole run. Connection failures surface immediately anyway.
REQUEST_TIMEOUT_S = 900.0
MAX_RETRIES = 2

# Local servers ignore the key but the SDK requires one to be present.
PLACEHOLDER_API_KEY = "local"

# For the settings field's placeholder text only — never used as a fallback.
# Defaulting to one of these would mean silently talking to whatever the user
# happens to have running, which is not a decision this code gets to make.
KNOWN_ENDPOINTS = {
    "Ollama": "http://localhost:11434/v1",
    "LM Studio": "http://localhost:1234/v1",
    "llama.cpp server": "http://localhost:8080/v1",
    "OpenAI": "https://api.openai.com/v1",
}


class OpenAICompatibleSession(LLMSession):
    """Chat completions over HTTP. Stateless — every call is one request."""

    def __init__(self, base_url: str, model: str, api_key: str | None = None) -> None:
        if not base_url:
            raise LLMError(
                "An OpenAI-compatible provider needs a base_url, e.g. "
                + KNOWN_ENDPOINTS["LM Studio"]
            )
        if not model:
            raise LLMError("An OpenAI-compatible provider needs a model name")

        self.model = model
        self.description = f"{base_url.rstrip('/')} ({model})"
        self._client = OpenAI(
            base_url=base_url,
            api_key=api_key or PLACEHOLDER_API_KEY,
            timeout=REQUEST_TIMEOUT_S,
            max_retries=MAX_RETRIES,
        )

    @classmethod
    def from_params(cls, params: dict) -> OpenAICompatibleSession:
        return cls(
            base_url=params.get("base_url", ""),
            model=params.get("model", ""),
            api_key=params.get("api_key"),
        )

    def stream(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
    ) -> Iterator[GenerationChunk]:
        params = sampling or SamplingParams()
        response_format: ResponseFormatJSONSchema | openai.Omit = omit
        if json_schema is not None:
            # Real constrained decoding on every server worth targeting
            # (Ollama and LM Studio both enforce it via XGrammar/Outlines).
            response_format = {
                "type": "json_schema",
                "json_schema": {"name": "result", "schema": json_schema, "strict": True},
            }

        try:
            stream = self._client.chat.completions.create(
                model=self.model,
                messages=cast(
                    list[ChatCompletionMessageParam],
                    [{"role": m["role"], "content": m["content"]} for m in messages],
                ),
                max_tokens=params.max_tokens,
                temperature=params.temperature,
                top_p=params.top_p if params.top_p > 0 else omit,
                seed=params.seed if params.seed is not None else omit,
                stop=list(stop) if stop else omit,
                response_format=response_format,
                stream=True,
                # Token counts are opt-in on a streamed response.
                stream_options={"include_usage": True},
                # top_k / min_p / repetition_penalty are not in the OpenAI
                # schema. Ollama and LM Studio accept them here; OpenAI itself
                # ignores unknown body fields rather than failing.
                extra_body=_extra_body(params),
            )
            yield from self._consume(stream)
        except openai.APIConnectionError as e:
            raise ProviderUnavailableError(f"Cannot reach {self.description}: {e}") from e
        except openai.APIStatusError as e:
            raise ProviderUnavailableError(
                f"{self.description} returned HTTP {e.status_code}: {e.message}"
            ) from e
        except openai.OpenAIError as e:
            raise LLMError(f"{self.description} failed: {e}") from e

    def _consume(self, stream: Any) -> Iterator[GenerationChunk]:
        """Turn SDK events into chunks, closing with a terminal one."""
        prompt_tokens = generation_tokens = 0
        finish_reason: str | None = None

        for event in stream:
            if usage := getattr(event, "usage", None):
                prompt_tokens = usage.prompt_tokens or prompt_tokens
                generation_tokens = usage.completion_tokens or generation_tokens

            for choice in event.choices:
                finish_reason = choice.finish_reason or finish_reason
                text = (choice.delta.content if choice.delta else None) or ""
                if text:
                    yield GenerationChunk(
                        text=text,
                        prompt_tokens=prompt_tokens,
                        generation_tokens=generation_tokens,
                    )

        # Always close the stream, so `generate` sees the final counters even
        # when the server sent no usage block at all.
        yield GenerationChunk(
            text="",
            prompt_tokens=prompt_tokens,
            generation_tokens=generation_tokens,
            done=True,
            finish_reason=finish_reason,
        )


def _extra_body(params: SamplingParams) -> dict[str, Any] | None:
    """Non-standard sampling knobs, sent only when actually set.

    top_k / min_p / repetition penalty are not in the OpenAI schema but every
    local server worth targeting accepts them, so they ride in extra_body
    rather than being silently dropped.
    """
    extra: dict[str, Any] = {}
    if params.top_k > 0:
        extra["top_k"] = params.top_k
    if params.min_p > 0:
        extra["min_p"] = params.min_p
    if params.repetition_penalty > 1.0:
        extra["repeat_penalty"] = params.repetition_penalty
    return extra or None
