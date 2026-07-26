"""Tests for the LLM seam — everything that does not need real weights.

Loading a model costs seconds and gigabytes, so the tests here exercise the
provider-independent parts: tier resolution, the JSON salvage path, session
assembly from a stream, and the warm-model pool's identity rules. A fake
session stands in for a backend, which is also the check that `LLMSession` is
implementable without importing mlx.
"""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from typing import Any

import pytest

from piko.core.llm import (
    CONTROLS,
    TIERS,
    GenerationChunk,
    LLMError,
    LLMSession,
    Message,
    SamplingParams,
    available_tiers,
    default_tier,
    extract_json,
    open_session,
    resolve_tier,
)
from piko.core.llm import pool as llm_pool
from piko.core.llm.registry import DEFAULT_TIER


class FakeSession(LLMSession):
    """A backend that replays a fixed script, one chunk per element."""

    def __init__(self, texts: Sequence[str], description: str = "fake") -> None:
        self.texts = list(texts)
        self.description = description
        self.calls: list[dict[str, Any]] = []
        self.closed = False

    def stream(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
    ) -> Iterator[GenerationChunk]:
        params = sampling or SamplingParams()
        self.calls.append({"temperature": params.temperature, "json_schema": json_schema})
        # Later calls in a retry loop replay the tail, so a test can make the
        # first attempt fail and the second succeed.
        text = self.texts[min(len(self.calls) - 1, len(self.texts) - 1)]
        for index, piece in enumerate(text):
            yield GenerationChunk(
                text=piece,
                prompt_tokens=7,
                generation_tokens=index + 1,
                done=index == len(text) - 1,
                finish_reason="stop" if index == len(text) - 1 else None,
            )

    def close(self) -> None:
        self.closed = True


# --- tier registry --------------------------------------------------------


def test_default_tier_is_the_balanced_one_on_a_big_machine():
    """PRODUCT.md's default must be the 4B tier wherever it fits."""
    assert DEFAULT_TIER == "balanced"
    assert TIERS["balanced"].repo == "mlx-community/Qwen3.5-4B-4bit"


def test_unknown_tier_falls_back_instead_of_raising():
    """A stale tier name saved by the UI must not break a run."""
    assert resolve_tier("does-not-exist").tier in TIERS
    assert resolve_tier(None).tier in TIERS


def test_available_tiers_are_ordered_and_never_empty():
    tiers = available_tiers()
    assert tiers
    assert [t.min_ram_mb for t in tiers] == sorted(t.min_ram_mb for t in tiers)


def test_the_ladder_climbs_and_the_ends_are_where_they_belong():
    """20B must never be offered on a 16 GB Mac; the smallest must fit 8 GB."""
    assert TIERS["max"].min_ram_mb > 16384
    assert TIERS["fast"].min_ram_mb <= 8192
    ordered = [spec.min_ram_mb for spec in sorted(TIERS.values(), key=lambda s: s.size_mb)]
    assert ordered == sorted(ordered), "a bigger model must not ask for less RAM"


def test_default_is_never_the_largest_tier_that_fits():
    """The 20B tier is opt-in even on a machine with room for it.

    A frontend deriving the default as "largest available" would silently make
    a 12 GB download the default on a big Mac — the exact bug this guards.
    """
    fits = {spec.tier for spec in available_tiers()}
    if "balanced" in fits:
        assert default_tier() == "balanced"
    assert default_tier() not in {"quality", "max"} or fits <= {"quality", "max"}


# --- JSON salvage ---------------------------------------------------------


@pytest.mark.parametrize(
    "raw",
    [
        '{"a": 1}',
        '```json\n{"a": 1}\n```',
        '```\n{"a": 1}\n```',
        'Sure! Here it is:\n{"a": 1}\nHope that helps.',
    ],
)
def test_extract_json_handles_every_shape_seen_in_the_bench(raw: str):
    assert extract_json(raw) == {"a": 1}


@pytest.mark.parametrize("raw", ["", "no json here", "{not json}", "[1, 2, 3]"])
def test_extract_json_returns_none_rather_than_guessing(raw: str):
    assert extract_json(raw) is None


# --- session mechanics ----------------------------------------------------


def test_generate_assembles_text_and_final_counters():
    session = FakeSession(["hey"])
    result = session.generate([{"role": "user", "content": "hi"}])

    assert result.text == "hey"
    assert result.generation_tokens == 3
    assert result.prompt_tokens == 7
    assert result.finish_reason == "stop"


def test_generate_reports_progress_per_chunk():
    session = FakeSession(["abc"])
    seen: list[str] = []
    session.generate([{"role": "user", "content": "hi"}], on_progress=lambda c: seen.append(c.text))
    assert seen == ["a", "b", "c"]


def test_generate_json_retries_with_a_hotter_sample():
    """First attempt is greedy; a malformed reply must not be re-rolled identically."""
    session = FakeSession(["not json at all", '{"ok": true}'])
    assert session.generate_json([{"role": "user", "content": "hi"}], {"type": "object"}) == {
        "ok": True
    }
    assert [c["temperature"] for c in session.calls] == [0.0, 0.4]


def test_generate_json_raises_after_exhausting_retries():
    session = FakeSession(["never json"])
    with pytest.raises(LLMError):
        session.generate_json([{"role": "user", "content": "hi"}], {"type": "object"}, retries=1)


def test_context_manager_closes_the_session():
    session = FakeSession(["x"])
    with session:
        pass
    assert session.closed


# --- sampling parameters --------------------------------------------------


def test_sampling_defaults_are_greedy():
    """Summarization is extraction: sampling invents attendees and decisions."""
    params = SamplingParams()
    assert params.temperature == 0.0
    assert params.top_p == 0.0
    assert params.top_k == 0
    assert params.repetition_penalty == 1.0


def test_sampling_params_clamp_out_of_range_values():
    """A slider that sends nonsense must degrade output, not wedge the decoder."""
    params = SamplingParams.from_params({"temperature": 50, "top_k": -5, "max_tokens": 10**9})
    assert params.temperature == 2.0
    assert params.top_k == 0
    assert params.max_tokens == 8192


def test_sampling_params_ignore_unparseable_values():
    params = SamplingParams.from_params({"temperature": "hot"})
    assert params.temperature == 0.0


def test_sampling_params_read_a_nested_block_or_a_flat_one():
    nested = SamplingParams.from_params({"sampling": {"temperature": 0.5}})
    flat = SamplingParams.from_params({"temperature": 0.5})
    assert nested.temperature == flat.temperature == 0.5


def test_every_control_is_a_real_field_with_a_matching_default():
    """The UI's sliders and the dataclass cannot drift apart."""
    defaults = SamplingParams().as_dict()
    for control in CONTROLS:
        assert control.key in defaults, f"{control.key} has no field"
        assert defaults[control.key] == pytest.approx(control.default)
        assert control.minimum <= control.default <= control.maximum


# --- provider dispatch ----------------------------------------------------


def test_unknown_provider_names_the_known_ones():
    with pytest.raises(LLMError, match="mlx"):
        open_session({"provider": "not-a-provider"})


def test_openai_provider_requires_a_base_url():
    """No silent default: pointing at whatever is on :11434 is not our call."""
    with pytest.raises(LLMError, match="base_url"):
        open_session({"provider": "openai", "model": "qwen"})


def test_openai_provider_requires_a_model():
    with pytest.raises(LLMError, match="model"):
        open_session({"provider": "openai", "base_url": "http://localhost:1234/v1"})


# --- warm pool ------------------------------------------------------------


def test_session_key_separates_tiers_and_endpoints():
    assert llm_pool.session_key({"tier": "fast"}) != llm_pool.session_key({"tier": "balanced"})
    assert llm_pool.session_key(None) == llm_pool.session_key({})
    remote = {"provider": "openai", "base_url": "http://a/v1", "model": "m"}
    assert llm_pool.session_key(remote) != llm_pool.session_key({"tier": "fast"})


def test_session_key_resolves_the_tier_before_keying():
    """An omitted tier and the tier it resolves to are the same model.

    Keying on the raw value made a warmup look like a miss to a request that
    left the field empty, reloading gigabytes for nothing.
    """
    assert llm_pool.session_key(None) == llm_pool.session_key({"tier": default_tier()})
    assert llm_pool.session_key({"tier": "nonsense"}) == llm_pool.session_key(None)


def test_pool_reuses_one_session_and_swaps_on_a_different_key(monkeypatch):
    """Two large models resident at once is the case 16 GB cannot afford."""
    built: list[FakeSession] = []

    def fake_open(params: dict | None = None) -> LLMSession:
        session = FakeSession(["x"], description=str(params))
        built.append(session)
        return session

    monkeypatch.setattr(llm_pool, "open_session", fake_open)
    llm_pool.release()
    try:
        first = llm_pool.acquire({"tier": "fast"})
        assert llm_pool.acquire({"tier": "fast"}) is first
        assert len(built) == 1

        second = llm_pool.acquire({"tier": "balanced"})
        assert second is not first
        assert built[0].closed, "the previous model must be freed before loading another"
    finally:
        llm_pool.release()


def test_pool_status_reports_whether_it_matches_the_request(monkeypatch):
    monkeypatch.setattr(llm_pool, "open_session", lambda params=None: FakeSession(["x"]))
    llm_pool.release()
    try:
        assert llm_pool.status({"tier": "fast"})["loaded"] is False
        llm_pool.acquire({"tier": "fast"})
        status = llm_pool.status({"tier": "fast"})
        assert status["loaded"] and status["matches_request"]
        assert llm_pool.status({"tier": "balanced"})["matches_request"] is False
    finally:
        llm_pool.release()
