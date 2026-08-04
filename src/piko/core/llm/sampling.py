"""Sampling knobs, their safe ranges, and the metadata the settings UI renders.

One source of truth on purpose: `CONTROLS` describes every knob — label, range,
step, default — and the frontend builds its sliders from it (shipped by
`list_llm_tiers`). A knob added here shows up in Settings without a Swift
change, and the two sides cannot drift into disagreeing about what "high
temperature" means.

Values arriving from the protocol are clamped, never trusted: a slider that
somehow sends temperature=50 must produce bad summaries, not a crash or a
wedged decode loop.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any

# Defaults are deliberately greedy. Summarization is an extraction task — the
# bench (bench/llm) ran everything at temperature 0, and creative sampling on a
# meeting summary invents attendees and decisions.
#
# `max_tokens` bounds the *generation* only — the prompt is not counted against
# it, and neither is the model's context window, which is two orders of
# magnitude larger (registry.py). It is therefore a ceiling, not an allocation:
# a stage that finishes its JSON in 300 tokens costs 300. The generous default
# is what stops the opposite failure, which is the expensive one — a reply cut
# off mid-object parses as nothing at all, so the whole stage is lost rather
# than shortened.
DEFAULT_MAX_TOKENS = 4096


@dataclass(frozen=True, slots=True)
class SamplingParams:
    """How to sample. Provider-independent; each backend maps it to its API."""

    max_tokens: int = DEFAULT_MAX_TOKENS
    temperature: float = 0.0
    top_p: float = 0.0
    """Nucleus sampling. 0 disables it (mlx-lm's convention)."""
    top_k: int = 0
    """0 disables it."""
    min_p: float = 0.0
    repetition_penalty: float = 1.0
    """1.0 is no penalty; the backends translate that to "off"."""
    seed: int | None = None

    @classmethod
    def from_params(cls, params: dict[str, Any] | None) -> SamplingParams:
        """Build from protocol params, clamping every value into its range."""
        params = params or {}
        # Accept both `{"sampling": {...}}` and the knobs inline, so a caller
        # can pass its whole params dict without unwrapping first.
        nested = params.get("sampling")
        raw: dict[str, Any] = nested if isinstance(nested, dict) else params
        values: dict[str, Any] = {}
        for control in CONTROLS:
            if control.key not in raw:
                continue
            values[control.key] = control.clamp(raw[control.key])

        seed = raw.get("seed")
        if isinstance(seed, int):
            values["seed"] = seed
        return cls(**values)

    def with_temperature(self, temperature: float) -> SamplingParams:
        return replace(self, temperature=temperature)

    def capped_at(self, max_tokens: int) -> SamplingParams:
        """The same knobs with a tighter output bound — never a looser one.

        For the stages whose output size is known in advance (one short object
        per deadline, say): the user's setting stays the ceiling, but a stage
        that cannot need 4096 tokens must not be handed 4096 tokens to loop in.
        """
        return replace(self, max_tokens=min(self.max_tokens, max_tokens))

    def as_dict(self) -> dict[str, Any]:
        return {
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "top_k": self.top_k,
            "min_p": self.min_p,
            "repetition_penalty": self.repetition_penalty,
            "seed": self.seed,
        }


@dataclass(frozen=True, slots=True)
class Control:
    """One knob, described well enough for a UI to render it unaided."""

    key: str
    label: str
    minimum: float
    maximum: float
    step: float
    default: float
    integer: bool
    help: str

    def clamp(self, value: Any) -> float | int:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return int(self.default) if self.integer else self.default
        number = max(self.minimum, min(self.maximum, number))
        return int(round(number)) if self.integer else number

    def as_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "label": self.label,
            "min": self.minimum,
            "max": self.maximum,
            "step": self.step,
            "default": self.default,
            "integer": self.integer,
            "help": self.help,
        }


CONTROLS: tuple[Control, ...] = (
    Control(
        key="temperature",
        label="Temperature",
        minimum=0.0,
        maximum=2.0,
        step=0.05,
        default=0.0,
        integer=False,
        help="0 keeps summaries faithful. Higher values invent detail.",
    ),
    Control(
        key="top_p",
        label="Top-p",
        minimum=0.0,
        maximum=1.0,
        step=0.05,
        default=0.0,
        integer=False,
        help="Sample only from the most likely tokens summing to this mass. 0 is off.",
    ),
    Control(
        key="top_k",
        label="Top-k",
        minimum=0,
        maximum=200,
        step=1,
        default=0,
        integer=True,
        help="Sample only from the k most likely tokens. 0 is off.",
    ),
    Control(
        key="min_p",
        label="Min-p",
        minimum=0.0,
        maximum=1.0,
        step=0.01,
        default=0.0,
        integer=False,
        help="Drop tokens far less likely than the best one. 0 is off.",
    ),
    Control(
        key="repetition_penalty",
        label="Repetition penalty",
        minimum=1.0,
        maximum=2.0,
        step=0.05,
        default=1.0,
        integer=False,
        help="Discourages loops. 1.0 is off.",
    ),
    Control(
        key="max_tokens",
        label="Max tokens",
        minimum=64,
        maximum=8192,
        step=64,
        default=DEFAULT_MAX_TOKENS,
        integer=True,
        help="Upper bound on one generation, prompt not included. Long meetings need more.",
    ),
)


def controls_payload() -> list[dict[str, Any]]:
    """The knob descriptions the settings UI renders."""
    return [control.as_dict() for control in CONTROLS]
