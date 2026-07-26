"""Embedded MLX backend — rung 1 of the runtime ladder (docs/ARCHITECTURE.md).

Runs mlx-lm in this process. The expensive part is the load (~2 s and several
GB for the balanced tier), which is why this is a session and not a function:
the process keeps the weights while the summary walks every chunk of a
transcript, and a warmed session can be handed straight to the next command.

Structured output is prompt-instructed, not grammar-constrained: upstream
mlx-lm exposes `logits_processors` but ships no JSON-schema enforcement (its
server has no `response_format` either — checked against SERVER.md). Bolting
on a constrained decoder (Outlines, the way LM Studio's mlx-engine does it, or
XGrammar) is the upgrade path; until then callers go through
`generate_json`, which parses and retries.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterator, Sequence
from typing import Any

# Importing mlx is slow (hundreds of ms) and pulls in Metal. That cost is
# deferred by importing *this module* lazily — session._open_mlx does it only
# when the mlx provider is actually selected — so everything here can be a
# normal module-level import.
import mlx.core as mx
from mlx.nn import Module
from mlx_lm import batch_generate, load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_logits_processors, make_sampler
from mlx_lm.tokenizer_utils import TokenizerWrapper

from ..memory import check_memory
from .registry import resolve_tier
from .sampling import SamplingParams
from .session import LLMSession
from .types import GenerationChunk, GenerationResult, LLMError, Message, ModelSpec

# Qwen3.5 is a hybrid-reasoning model; summarization does not benefit from
# thinking tokens and pays for them in latency, so they are off by default.
# Harmless for templates that do not define the variable — Jinja ignores it.
CHAT_TEMPLATE_KWARGS: dict[str, Any] = {"enable_thinking": False}

# How many prompts decode together in generate_batch. The KV cache grows with
# this, so it is a memory knob first and a speed knob second — 8 keeps the
# balanced tier's peak within the budget measured in bench/llm.
BATCH_SIZE = 8

_JSON_INSTRUCTION = (
    "Respond with a single JSON object and nothing else — no prose, no code "
    "fence. It must match this JSON Schema exactly, including every key in "
    '"required":\n{schema}'
)


class MLXSession(LLMSession):
    """A loaded local model, callable until closed."""

    # Cleared by close() to drop the weights, hence optional. Reach them
    # through `_loaded()` so use-after-close is a clear error, not an
    # AttributeError from somewhere inside mlx.
    _model: Module | None
    _tokenizer: TokenizerWrapper | None

    def __init__(self, spec: ModelSpec) -> None:
        self.spec = spec
        self.description = f"{spec.name} ({spec.tier})"

        # Pre-flight: refuse before touching the weights rather than dying
        # halfway through a 3 GB read.
        check_memory(spec.ram_mb, self.description)

        # load() returns (model, tokenizer), or a 3-tuple with the config when
        # return_config is set — index rather than unpack so the signature's
        # union does not leak into the type of these attributes.
        loaded = load(spec.repo)
        self._model, self._tokenizer = loaded[0], loaded[1]

    @classmethod
    def from_params(cls, params: dict) -> MLXSession:
        return cls(resolve_tier(params.get("tier")))

    def _loaded(self) -> tuple[Module, TokenizerWrapper]:
        if self._model is None or self._tokenizer is None:
            raise LLMError(f"{self.description} was closed; open a new session")
        return self._model, self._tokenizer

    def _render_prompt(
        self, messages: Sequence[Message], json_schema: dict[str, Any] | None
    ) -> str:
        turns: list[dict[str, str]] = [
            {"role": m["role"], "content": m["content"]} for m in messages
        ]
        if json_schema is not None:
            turns = _with_json_instruction(turns, json_schema)

        _, tokenizer = self._loaded()
        try:
            rendered = tokenizer.apply_chat_template(
                turns, tokenize=False, add_generation_prompt=True, **CHAT_TEMPLATE_KWARGS
            )
        except (TypeError, ValueError):
            # Template does not accept our kwargs (or has none at all).
            rendered = tokenizer.apply_chat_template(
                turns, tokenize=False, add_generation_prompt=True
            )
        return str(rendered)

    def stream(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
    ) -> Iterator[GenerationChunk]:
        if not messages:
            raise LLMError("stream() needs at least one message")

        params = sampling or SamplingParams()
        model, tokenizer = self._loaded()
        prompt = self._render_prompt(messages, json_schema)
        # A fresh cache per call: consecutive summary chunks share only the
        # system prompt, and reusing a positional KV cache across unrelated
        # prompts would silently corrupt the context.
        cache = make_prompt_cache(model)
        sampler = make_sampler(
            temp=params.temperature,
            top_p=params.top_p,
            min_p=params.min_p,
            top_k=params.top_k,
        )
        # mlx-lm treats 1.0 and None alike, but passing None skips building the
        # processor at all.
        processors = (
            make_logits_processors(repetition_penalty=params.repetition_penalty)
            if params.repetition_penalty > 1.0
            else None
        )
        if params.seed is not None:
            mx.random.seed(params.seed)

        produced: list[str] = []
        for response in stream_generate(
            model,
            tokenizer,
            prompt,
            max_tokens=params.max_tokens,
            sampler=sampler,
            logits_processors=processors,
            prompt_cache=cache,
        ):
            text = response.text
            produced.append(text)

            trimmed, hit_stop = _apply_stop(produced, text, stop)
            done = hit_stop or response.finish_reason is not None
            yield GenerationChunk(
                text=trimmed,
                prompt_tokens=response.prompt_tokens,
                generation_tokens=response.generation_tokens,
                done=done,
                finish_reason="stop" if hit_stop else response.finish_reason,
                prompt_tps=response.prompt_tps,
                generation_tps=response.generation_tps,
                peak_memory_mb=response.peak_memory * 1024,
            )
            if hit_stop:
                return

    def generate_batch(
        self,
        conversations: Sequence[Sequence[Message]],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        on_done: Callable[[int], None] | None = None,
    ) -> list[GenerationResult]:
        """One forward pass over many prompts — the map phase of a summary.

        Real batching, not a loop: mlx-lm's BatchGenerator decodes every prompt
        together, so N chunks cost far less than N sequential generations.
        `completion_batch_size` caps how many run at once, because the KV cache
        grows with it and the whole point of the tier system is not to blow the
        memory budget.
        """
        if not conversations:
            return []

        params = sampling or SamplingParams()
        model, tokenizer = self._loaded()
        prompts = [
            tokenizer.encode(self._render_prompt(conversation, json_schema))
            for conversation in conversations
        ]
        if params.seed is not None:
            mx.random.seed(params.seed)

        response = batch_generate(
            model,
            tokenizer,
            prompts,
            max_tokens=params.max_tokens,
            sampler=make_sampler(
                temp=params.temperature,
                top_p=params.top_p,
                min_p=params.min_p,
                top_k=params.top_k,
            ),
            completion_batch_size=BATCH_SIZE,
        )
        if on_done is not None:
            on_done(len(response.texts))

        return [
            GenerationResult(
                text=text,
                prompt_tokens=len(prompt),
                generation_tokens=len(tokenizer.encode(text)),
            )
            for text, prompt in zip(response.texts, prompts, strict=False)
        ]

    def warmup(self) -> None:
        """Force the first (slowest) decode so the next real call is fast.

        Loading weights is not the whole cost: the first generation also
        compiles Metal kernels and allocates the KV buffers. One token on a
        trivial prompt pays that once, off the user's critical path.
        """
        for _ in self.stream(
            [{"role": "user", "content": "Hi"}], sampling=SamplingParams(max_tokens=1)
        ):
            break

    def close(self) -> None:
        self._model = None
        self._tokenizer = None


def _with_json_instruction(
    turns: list[dict[str, str]], schema: dict[str, Any]
) -> list[dict[str, str]]:
    """Append the schema to the system turn, adding one if the caller sent none."""
    instruction = _JSON_INSTRUCTION.format(schema=json.dumps(schema, ensure_ascii=False))
    for turn in turns:
        if turn.get("role") == "system":
            turn["content"] = f"{turn['content']}\n\n{instruction}"
            return turns
    return [{"role": "system", "content": instruction}, *turns]


def _apply_stop(produced: list[str], text: str, stop: Sequence[str] | None) -> tuple[str, bool]:
    """Cut `text` at the first stop string. Returns (text to emit, stopped?).

    mlx-lm has no stop-string support, and a stop sequence can straddle two
    chunks, so the check runs against everything produced so far.
    """
    if not stop:
        return text, False
    whole = "".join(produced)
    for marker in stop:
        index = whole.find(marker)
        if index >= 0:
            keep = len(whole) - index
            return (text[:-keep] if keep <= len(text) else ""), True
    return text, False
