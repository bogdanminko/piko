"""Tests for the LLM seam — everything that does not need real weights.

Loading a model costs seconds and gigabytes, so the tests here exercise the
provider-independent parts: tier resolution, the JSON salvage path, session
assembly from a stream, and the warm-model pool's identity rules. A fake
session stands in for a backend, which is also the check that `LLMSession` is
implementable without importing mlx.
"""

from __future__ import annotations

import time
from collections.abc import Iterator, Sequence
from typing import Any, cast

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
        reuse_cache: bool = False,
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
    """The smallest must fit 8 GB, and a bigger model must never ask for less."""
    assert TIERS["fast"].min_ram_mb <= 8192
    ordered = [spec.min_ram_mb for spec in sorted(TIERS.values(), key=lambda s: s.size_mb)]
    assert ordered == sorted(ordered), "a bigger model must not ask for less RAM"


def test_nothing_larger_than_the_quality_tier_is_offered():
    """Deliberate, and worth a test because it is a decision, not an oversight.

    Both candidates for a fourth rung argued against themselves: GPT-OSS 20B by
    being the only non-Qwen here (harmony format, an analysis channel in the
    text stream), and Qwen3.6-35B-A3B by needing 20.4 GB — refused by the
    pre-flight check on a 36 GB Mac with an ordinary desktop open. A tier that
    is offered and then declines to load is worse than one never offered.
    """
    assert set(TIERS) == {"fast", "balanced", "quality"}
    assert max(spec.size_mb for spec in TIERS.values()) < 8000


def test_default_is_never_the_largest_tier_that_fits():
    """`quality` is opt-in even on a machine with room for it.

    A frontend deriving the default as "largest available" would silently make
    a 6 GB download the default on a big Mac — the exact bug this guards.
    """
    fits = {spec.tier for spec in available_tiers()}
    if "balanced" in fits:
        assert default_tier() == "balanced"
    assert default_tier() != "quality" or fits == {"quality"}


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


@pytest.mark.parametrize(
    "raw",
    [
        # Qwen, when a template will not take enable_thinking.
        '<think>\nThe schema wants {"a": 1}. Careful with {braces}.\n</think>\n{"a": 1}',
        # GPT-OSS: harmony has no way to switch reasoning off, only down.
        '<|channel|>analysis<|message|>Draft: {"a": 2}? No, {"a": 1}.'
        '<|end|><|start|>assistant<|channel|>final<|message|>{"a": 1}',
    ],
)
def test_extract_json_reads_the_answer_not_the_reasoning(raw: str):
    """Verified against GPT-OSS 20B, where this was not a hypothetical: the
    model's analysis quotes the JSON it is about to write, so a scan from the
    first "{" spanned the reasoning and the whole reply parsed as nothing."""
    assert extract_json(raw) == {"a": 1}


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


def test_capped_at_only_ever_lowers_the_output_bound():
    """A stage may know it needs less than the user allowed. It may never
    decide it needs more."""
    params = SamplingParams(max_tokens=1000, temperature=0.3)
    assert params.capped_at(200).max_tokens == 200
    assert params.capped_at(9000).max_tokens == 1000
    assert params.capped_at(200).temperature == 0.3, "only the bound moves"


def test_every_control_is_a_real_field_with_a_matching_default():
    """The UI's sliders and the dataclass cannot drift apart."""
    defaults = SamplingParams().as_dict()
    for control in CONTROLS:
        assert control.key in defaults, f"{control.key} has no field"
        assert defaults[control.key] == pytest.approx(control.default)
        assert control.minimum <= control.default <= control.maximum


# --- chat template ---------------------------------------------------------
#
# The one test here that does need mlx on the machine, hence the importorskip:
# what it guards is a *silent* fallback, and silence is not observable from
# anywhere else.


def test_a_template_that_refuses_our_kwargs_says_so_once(capsys):
    """Reasoning switched back on unnoticed looks like "the summary got slow
    and stopped parsing", which is a long way from its cause."""
    pytest.importorskip("mlx", reason="the MLX backend is not installed here")
    from piko.core.llm.mlx_backend import MLXSession

    class StubTokenizer:
        """Renders, but only when nobody passes it template kwargs."""

        def apply_chat_template(self, turns: Any, **kwargs: Any) -> str:
            if "enable_thinking" in kwargs:
                raise TypeError("unexpected keyword argument 'enable_thinking'")
            return "rendered"

    # No weights: rendering a prompt needs the tokenizer and nothing else.
    session = MLXSession.__new__(MLXSession)
    session.description = "stub"
    session._template_kwargs = True
    session._model = cast(Any, object())
    session._tokenizer = cast(Any, StubTokenizer())

    turns: list[Message] = [{"role": "user", "content": "hi"}]
    assert session._render_prompt(turns, None) == "rendered"
    assert session._render_prompt(turns, None) == "rendered"

    warnings = [line for line in capsys.readouterr().err.splitlines() if "chat template" in line]
    assert len(warnings) == 1, "once per session — per chunk would bury it"


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


# --- The open artifact as context -------------------------------------------


def test_artifact_text_reaches_the_prompt() -> None:
    """The words on screen, not a sentence saying words are on screen."""
    from piko.commands.chat import _conversation

    turns = _conversation(
        {
            "messages": [{"role": "user", "content": "who owns the pilot?"}],
            "context": "a call is open.",
            "artifact": "00:02 Anna will prepare the pilot by Friday.",
        }
    )
    sheet = turns[0]["content"]
    assert "Anna will prepare the pilot" in sheet
    assert "--- begin artifact ---" in sheet


def test_no_artifact_costs_no_context() -> None:
    """An idle chat must not carry an empty artifact block."""
    from piko.commands.chat import _conversation

    turns = _conversation({"messages": [{"role": "user", "content": "hi"}]})
    assert "begin artifact" not in turns[0]["content"]


def test_long_artifact_keeps_both_ends() -> None:
    """A call's opening says what it is about; its closing says what was agreed."""
    from piko.commands.chat import MAX_ARTIFACT_CHARS, _conversation

    body = "START-MARKER " + ("filler " * 40_000) + " END-MARKER"
    turns = _conversation({"messages": [{"role": "user", "content": "?"}], "artifact": body})
    sheet = turns[0]["content"]
    assert "START-MARKER" in sheet
    assert "END-MARKER" in sheet
    assert "omitted from the middle" in sheet
    assert len(sheet) < MAX_ARTIFACT_CHARS + 3_000


def test_history_has_a_character_budget() -> None:
    """Twelve turns is not a budget when one turn can carry a pasted transcript."""
    from piko.commands.chat import MAX_HISTORY_CHARS, _conversation

    huge = "x" * 200_000
    turns = _conversation(
        {"messages": [{"role": "user", "content": huge}, {"role": "user", "content": "so?"}]}
    )
    body = "".join(turn["content"] for turn in turns[1:])
    assert len(body) < MAX_HISTORY_CHARS + 2_000


def test_the_newest_turn_survives_a_full_history() -> None:
    """Spent newest-first: the question just asked must reach the model."""
    from piko.commands.chat import _conversation

    messages = [{"role": "user", "content": "y" * 20_000}, {"role": "user", "content": "MARKER"}]
    turns = _conversation({"messages": messages})
    assert "MARKER" in turns[-1]["content"]


# --- Keeping the model, and giving the memory back ---------------------------


def test_status_reports_residency_and_the_idle_rule() -> None:
    """The card in the sidebar shows these; they must exist even with nothing loaded."""
    from piko.core.llm import pool

    status = pool.status({})
    assert status["loaded"] is False
    assert "idle_seconds" in status
    assert status["releases_after"] == pool.IDLE_RELEASE_SECONDS


def test_in_use_is_safe_with_nothing_loaded() -> None:
    """Trimming scratch memory must never be the thing that breaks a run."""
    from piko.core.llm import pool

    with pool.in_use():
        pass
    pool.release()


def test_busy_work_is_not_swept_away(monkeypatch) -> None:
    """An idle timer keyed on acquisition alone would free weights mid-summary."""
    from piko.core.llm import pool

    monkeypatch.setattr(pool, "_session", object())
    monkeypatch.setattr(pool, "_last_used", 0.0)  # ancient
    with pool.in_use():
        assert pool._busy == 1
    assert pool._busy == 0
    # Leaving the block counts as use, so the sweeper's clock restarts.
    assert pool.status({})["idle_seconds"] < 1
    monkeypatch.setattr(pool, "_session", None)


def test_generation_is_serialised_against_the_warmup() -> None:
    """Two threads evaluating one MLX graph is a SIGSEGV, not a race you can catch.

    Nothing needed this while every command was its own process; a resident one
    puts a background warmup and a foreground question on the same weights.
    """
    import threading

    from piko.core.llm import pool

    order: list[str] = []
    entered = threading.Event()

    def hold() -> None:
        with pool.in_use():
            order.append("warmup-in")
            entered.set()
            time.sleep(0.3)
            order.append("warmup-out")

    thread = threading.Thread(target=hold)
    thread.start()
    entered.wait(timeout=2)
    with pool.in_use():
        order.append("chat-in")
    thread.join(timeout=5)

    assert order == ["warmup-in", "warmup-out", "chat-in"]


# --- A model's thinking is not the answer -----------------------------------


def test_harmony_analysis_never_reaches_the_bubble() -> None:
    """Picking the old `max` tier put the model's private channel on screen."""
    from piko.commands.reasoning import ReasoningFilter

    stream = [
        "<|channel|>analysis<|message|>Need to answer: yes, it can.",
        "<|end|><|start|>assistant<|channel|>final<|message|>",
        "Yes, Piko can burn subtitles.",
    ]
    out = ReasoningFilter()
    visible = "".join(out.feed(chunk) for chunk in stream)
    assert visible == "Yes, Piko can burn subtitles."
    assert "<|channel|>" not in visible


def test_think_block_is_held_back_too() -> None:
    """Qwen opens `<think>` even with enable_thinking off; same rule applies."""
    from piko.commands.reasoning import ReasoningFilter

    out = ReasoningFilter()
    visible = "".join(
        out.feed(c) for c in ["<think>", "hmm, weighing it", "</think>", "The answer."]
    )
    assert visible == "The answer."


def test_a_plain_answer_streams_from_the_first_token() -> None:
    """A model that never reasons must not be buffered waiting for an end marker."""
    from piko.commands.reasoning import ReasoningFilter

    out = ReasoningFilter()
    assert out.feed("Yes") == "Yes"
    assert out.feed(", it can.") == ", it can."
    assert out.is_thinking is False


def test_a_marker_split_across_chunks_is_still_caught() -> None:
    """Tokens do not arrive on marker boundaries; deciding per chunk would leak."""
    from piko.commands.reasoning import ReasoningFilter

    out = ReasoningFilter()
    pieces = ["<th", "ink>", "reasoning", "</think>", "Done."]
    assert "".join(out.feed(p) for p in pieces) == "Done."
