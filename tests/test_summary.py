"""Tests for the summarizer's deterministic half.

Everything a model produces is untrusted input here: what matters is that a
citation either resolves to a real second or is dropped, that nothing exceeds
what the cards can display, and that chunking never splits a line. None of
these need weights.
"""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from typing import Any

from piko.core.llm import GenerationChunk, LLMSession, Message, SamplingParams
from piko.skills.meeting.summary import (
    NOTES_RULES,
    Budgets,
    _chunk_message,
    _clip,
    _dedupe,
    _notes_for,
    _notes_message,
    _over_budget,
    _resolve,
    _truncate,
    anchor_notes,
    chunk_lines,
    detect_language,
    language_name,
    numbered_lines,
    resolve_due_dates,
    summarize,
)

SEGMENTS = [
    {"start": 0.0, "end": 5.0, "text": "Начинаем.", "speaker": "me"},
    {"start": 5.0, "end": 9.0, "text": "  ", "speaker": "them"},  # dropped: empty
    {"start": 9.0, "end": 14.0, "text": "Решили выпускать в пятницу.", "speaker": "them"},
]
SPEAKERS = {"me": "You", "them": "Participants"}


# --- numbering ------------------------------------------------------------


def test_lines_are_numbered_from_one_and_skip_empty_segments():
    lines = numbered_lines(SEGMENTS, SPEAKERS)
    assert [line.number for line in lines] == [1, 2]
    assert [line.start for line in lines] == [0.0, 9.0]
    assert lines[0].speaker == "You"


def test_rendered_line_leads_with_its_number():
    """The number is the citation handle — it has to be unmissable."""
    line = numbered_lines(SEGMENTS, SPEAKERS)[1]
    assert line.render().startswith("[2] Participants:")


# --- chunking -------------------------------------------------------------


def test_chunking_never_splits_a_line():
    lines = numbered_lines(
        [{"start": i, "end": i + 1, "text": f"line {i} " + "x" * 200} for i in range(40)]
    )
    chunks = chunk_lines(lines, budget_chars=1000, overlap_chars=200)

    assert len(chunks) > 1
    rendered = [line.render() for chunk in chunks for line in chunk]
    for text in rendered:
        assert text.startswith("[")


def test_chunks_overlap_so_a_boundary_statement_is_seen_twice():
    lines = numbered_lines([{"start": i, "end": i + 1, "text": "y" * 100} for i in range(30)])
    chunks = chunk_lines(lines, budget_chars=800, overlap_chars=300)

    first_numbers = {line.number for line in chunks[0]}
    second_numbers = {line.number for line in chunks[1]}
    assert first_numbers & second_numbers, "chunks must share their seam"


def test_every_line_appears_in_some_chunk():
    lines = numbered_lines([{"start": i, "end": i + 1, "text": f"segment {i}"} for i in range(50)])
    covered = {line.number for chunk in chunk_lines(lines, 400, 80) for line in chunk}
    assert covered == {line.number for line in lines}


def test_empty_transcript_yields_no_chunks():
    assert chunk_lines([]) == []


# --- citation resolution --------------------------------------------------

STARTS = {1: 0.0, 2: 9.0, 3: 30.0}


def test_refs_resolve_to_the_second_the_line_starts_at():
    items = [{"text": "Ship on Friday", "ref": 2}]
    assert _resolve(items, STARTS) == [{"text": "Ship on Friday", "start": 9.0}]


def test_unresolvable_refs_are_dropped_not_guessed():
    """A summary with fewer items is honest; an invented timecode is not."""
    items: list[dict] = [
        {"text": "Real", "ref": 1},
        {"text": "Hallucinated line number", "ref": 999},
        {"text": "No ref at all"},
        {"text": "Ref is not an integer", "ref": "12:40"},
        {"text": "", "ref": 1},
    ]
    assert [item["text"] for item in _resolve(items, STARTS)] == ["Real"]


def test_items_come_back_in_transcript_order():
    items = [{"text": "later", "ref": 3}, {"text": "earlier", "ref": 1}]
    assert [item["text"] for item in _resolve(items, STARTS)] == ["earlier", "later"]


def test_owner_and_due_survive_but_speaker_labels_do_not():
    """ "Participants" is who spoke, never who owns the task."""
    items = [
        {"text": "Task A", "ref": 1, "owner": "Аня", "due": "Aug 5"},
        {"text": "Task B", "ref": 2, "owner": "Participants"},
    ]
    resolved = _resolve(items, STARTS, frozenset({"participants", "you"}))
    assert resolved[0]["owner"] == "Аня"
    assert resolved[0]["due"] == "Aug 5"
    assert "owner" not in resolved[1]


def test_duplicates_across_overlapping_chunks_collapse():
    items = [
        {"text": "Ship on Friday", "start": 9.0},
        {"text": "ship on friday!", "start": 30.0},
    ]
    assert len(_dedupe(items)) == 1


# --- notes the user typed -------------------------------------------------
#
# The one input in this pipeline that no model produced. Two things have to
# hold: a note is never lost (not to a missing timecode, not to a chunk that
# failed extraction), and it never gains a citation it did not earn — a note
# handed to a chunk that cannot see its line would be inviting exactly the
# invented "ref" the rest of the module exists to prevent.

LINES = numbered_lines(
    [
        {"start": 0.0, "text": "Начинаем.", "speaker": "me"},
        {"start": 10.0, "text": "Кирил берёт миграцию.", "speaker": "them"},
        {"start": 30.0, "text": "Выпускаем в пятницу.", "speaker": "them"},
    ]
)


def test_a_note_anchors_to_the_line_that_had_started_when_it_was_typed():
    """A note is written *after* the thing it is about was said, so the anchor
    is the line before it, never the one that comes next."""
    [note] = anchor_notes([{"at": 12.0, "text": "Kirill Zh., not Кирил"}], LINES)
    assert note.ref == 2
    assert note.render() == "[2] Kirill Zh., not Кирил"


def test_a_note_typed_before_anyone_spoke_anchors_to_the_first_line():
    [note] = anchor_notes([{"at": 0.0, "text": "agenda"}], LINES)
    assert note.ref == 1


def test_an_untimed_note_keeps_its_text_and_loses_only_the_citation():
    """An import has no clock, and a line added after the call has no place on
    the axis. Dropping the text to save the timecode loses the wrong half."""
    [note] = anchor_notes([{"text": "no clock here"}], LINES)
    assert note.ref is None
    assert note.text == "no clock here"
    # Never "[?]": a question mark where a line number belongs is an invitation
    # to fill one in, and an invented ref is what the citation scheme forbids.
    assert note.render() == "(no line) no clock here"


def test_blank_notes_are_dropped():
    assert anchor_notes([{"at": 1.0, "text": "   "}, {"at": 2.0, "text": ""}], LINES) == []


def test_notes_come_back_in_time_order_with_the_untimed_last():
    notes = anchor_notes(
        [{"at": 30.0, "text": "late"}, {"text": "no time"}, {"at": 1.0, "text": "early"}], LINES
    )
    assert [note.text for note in notes] == ["early", "late", "no time"]


def test_a_chunk_is_only_given_the_notes_whose_line_it_holds():
    notes = anchor_notes([{"at": 0.0, "text": "first"}, {"at": 30.0, "text": "third"}], LINES)
    assert [note.text for note in _notes_for(LINES[:1], notes)] == ["first"]
    assert [note.text for note in _notes_for(LINES[2:], notes)] == ["third"]


def test_an_untimed_note_reaches_no_chunk_at_all():
    notes = anchor_notes([{"text": "no clock"}], LINES)
    assert _notes_for(LINES, notes) == []


def test_the_reduce_step_is_shown_every_note_including_the_uncitable_ones():
    notes = anchor_notes([{"at": 10.0, "text": "timed one"}, {"text": "untimed one"}], LINES)
    message = _notes_message([{"notes": "part"}], "Russian", notes)

    assert "timed one" in message and "untimed one" in message
    assert "<user_notes>" in message


def test_a_meeting_without_notes_carries_no_notes_tag_anywhere():
    """A rule about a tag that is not in the message is an invitation to invent
    one, so the block and its rules both have to be absent, not empty."""
    assert "<user_notes>" not in _chunk_message(LINES, "Russian")
    assert "<user_notes>" not in _notes_message([{"notes": "part"}], "Russian")


def test_notes_reach_the_extraction_prompt_with_their_rules():
    session = _session(_BOTH_SCHEMAS)
    summarize(
        session,
        SEGMENTS,
        speakers=SPEAKERS,
        notes=[{"at": 9.5, "text": "дедлайн — среда, не пятница"}],
    )

    prompts = [
        "\n".join(str(message["content"]) for message in call["messages"]) for call in session.calls
    ]
    assert any("дедлайн — среда" in prompt for prompt in prompts)
    assert all(NOTES_RULES in prompt for prompt in prompts if "<user_notes>" in prompt)


def test_a_summary_without_notes_prompts_exactly_as_it_did_before():
    session = _session(_BOTH_SCHEMAS)
    summarize(session, SEGMENTS, speakers=SPEAKERS)

    everything = "\n".join(
        str(message["content"]) for call in session.calls for message in call["messages"]
    )
    assert "<user_notes>" not in everything
    assert NOTES_RULES not in everything


# --- display budgets ------------------------------------------------------

TIGHT = Budgets(
    brief_chars=20, summary_chars=40, topics=1, decisions=1, action_items=1, open_questions=1
)


def test_over_budget_detects_each_field():
    assert _over_budget({"brief": "x" * 21}, TIGHT)
    assert _over_budget({"topics": ["a", "b"]}, TIGHT)
    assert not _over_budget({"brief": "short", "topics": ["a"]}, TIGHT)


def test_truncate_brings_everything_within_the_cards():
    result = _truncate(
        {
            "brief": "x" * 200,
            "summary": "y" * 500,
            "topics": ["a", "b", "c"],
            "decisions": [{"text": "1"}, {"text": "2"}],
            "action_items": [{"text": "1"}, {"text": "2"}],
            "open_questions": [{"text": "1"}, {"text": "2"}],
        },
        TIGHT,
    )
    assert not _over_budget(result, TIGHT)
    assert len(result["topics"]) == 1


def test_clip_prefers_a_sentence_end_so_the_text_reads_as_finished():
    text = "First sentence here. " + "tail " * 20
    clipped = _clip(text, 40)
    assert clipped.startswith("First sentence here.")
    assert clipped.endswith("…")


def test_clip_leaves_short_text_untouched():
    assert _clip("already short", 100) == "already short"


# --- language -------------------------------------------------------------


def test_language_code_becomes_a_name_the_prompt_can_use():
    """ "Russian" holds against an English system prompt; "ru" does not."""
    assert language_name("ru") == "Russian"
    assert language_name("en-US") == "English"


def test_unknown_language_falls_back_to_a_usable_phrase():
    assert language_name(None) == "the language of the transcript"
    assert language_name("unknown") == "the language of the transcript"
    assert language_name("xx") == "xx"


def test_language_is_detected_when_asr_reports_none():
    """Parakeet returns no language code, so a real recording arrives as
    "unknown" — and an unnamed target is what makes the model answer in the
    language of its English prompt instead of the transcript's."""
    assert detect_language("Давайте перенесём релиз на пятницу, я обновлю changelog") == "ru"
    assert detect_language("Let us move the release and I will update the changelog") == "en"
    assert detect_language("Wir haben das nicht besprochen und die Frage ist offen") == "de"
    assert detect_language("Nous avons des questions pour les tests dans une semaine") == "fr"


def test_ukrainian_is_not_mistaken_for_russian():
    assert detect_language("Ми маємо підготувати звіт із цієї теми") == "uk"


def test_detection_declines_rather_than_guessing_on_thin_input():
    assert detect_language("") is None
    assert detect_language("12345 !!! ...") is None
    assert detect_language("ok") is None


# --- due dates ------------------------------------------------------------
#
# The model is untrusted here too: a date is used only if it parses, sits on or
# after the meeting, and lands inside the horizon. Anything else is dropped —
# a task with no date beats a task due on an invented one.


class FakeSession(LLMSession):
    """Replays one canned answer and records whether it was called at all."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.description = "fake"
        self.calls: list[dict[str, Any]] = []

    def stream(
        self,
        messages: Sequence[Message],
        *,
        sampling: SamplingParams | None = None,
        json_schema: dict[str, Any] | None = None,
        stop: Sequence[str] | None = None,
        reuse_cache: bool = False,
    ) -> Iterator[GenerationChunk]:
        self.calls.append({"messages": list(messages), "sampling": sampling})
        yield GenerationChunk(
            text=self.text, prompt_tokens=7, generation_tokens=1, done=True, finish_reason="stop"
        )

    def close(self) -> None:
        pass


def _session(payload: str) -> FakeSession:
    return FakeSession(payload)


def test_spoken_deadline_becomes_a_date_and_keeps_the_phrase():
    items = [{"text": "Collect the eval set", "start": 12.0, "due": "by the fifth of August"}]
    resolve_due_dates(
        _session('{"dates":[{"index":0,"date":"2026-08-05","time":null}]}'),
        items,
        "2026-07-26T18:01:00Z",
    )

    assert items[0]["due_date"] == "2026-08-05"
    assert items[0]["due"] == "by the fifth of August", "the spoken phrase is the evidence"
    assert "due_time" not in items[0]


def test_stated_time_of_day_is_carried_over():
    items = [{"text": "Send the deck", "start": 4.0, "due": "tomorrow at noon"}]
    resolve_due_dates(
        _session('{"dates":[{"index":0,"date":"2026-07-27","time":"12:00"}]}'), items, "2026-07-26"
    )

    assert (items[0]["due_date"], items[0]["due_time"]) == ("2026-07-27", "12:00")


def test_a_date_before_the_meeting_is_refused():
    """Almost always the model losing the anchor and answering from its own
    idea of "today"."""
    items = [{"text": "Ship it", "start": 1.0, "due": "by Friday"}]
    resolve_due_dates(_session('{"dates":[{"index":0,"date":"2024-01-05"}]}'), items, "2026-07-26")

    assert "due_date" not in items[0]


def test_a_date_beyond_the_horizon_is_refused():
    items = [{"text": "Ship it", "start": 1.0, "due": "by Friday"}]
    resolve_due_dates(_session('{"dates":[{"index":0,"date":"2031-07-26"}]}'), items, "2026-07-26")

    assert "due_date" not in items[0]


def test_malformed_and_null_dates_are_dropped_not_guessed():
    items = [
        {"text": "One", "start": 1.0, "due": "later"},
        {"text": "Two", "start": 2.0, "due": "soon"},
    ]
    resolve_due_dates(
        _session('{"dates":[{"index":0,"date":null},{"index":1,"date":"next friday"}]}'),
        items,
        "2026-07-26",
    )

    assert all("due_date" not in item for item in items)


def test_items_without_a_spoken_deadline_are_never_sent_to_the_model():
    items = [{"text": "No deadline here", "start": 1.0}]
    session = _session('{"dates":[{"index":0,"date":"2026-08-05"}]}')
    resolve_due_dates(session, items, "2026-07-26")

    assert session.calls == [], "nothing to resolve means no model call"
    assert "due_date" not in items[0]


def test_an_unusable_meeting_date_skips_resolution_entirely():
    items = [{"text": "Ship it", "start": 1.0, "due": "by Friday"}]
    session = _session('{"dates":[{"index":0,"date":"2026-08-05"}]}')
    resolve_due_dates(session, items, "")

    assert session.calls == []
    assert "due_date" not in items[0]


# --- sampling settings -----------------------------------------------------
#
# The knobs on the Models screen were, for a while, rendered from the backend,
# stored, sent — and then ignored by this module, which sampled at constants of
# its own. Nothing about that was visible from the outside: the summary simply
# came out as if the sliders did not exist. Hence a test per end of the wire.

# One object that satisfies both schemas, so the same canned reply works for
# the extract stage and the reduce stage.
_BOTH_SCHEMAS = (
    '{"notes":"Release talk","topics":["release"],'
    '"decisions":[{"text":"Ship on Friday","ref":2}],'
    '"action_items":[],"open_questions":[],'
    '"brief":"We ship on Friday.","summary":"The call settled the date."}'
)


def test_the_sampling_setting_reaches_every_stage():
    session = _session(_BOTH_SCHEMAS)
    summarize(session, SEGMENTS, speakers=SPEAKERS, sampling=SamplingParams(max_tokens=2048))

    assert session.calls, "the summary has to have called the model at all"
    assert {call["sampling"].max_tokens for call in session.calls} == {2048}


def test_a_stage_never_raises_the_ceiling_it_was_given():
    """A low setting is a limit, not a suggestion — including for the stages
    that used to ask for more than it."""
    session = _session(_BOTH_SCHEMAS)
    summarize(session, SEGMENTS, speakers=SPEAKERS, sampling=SamplingParams(max_tokens=128))

    assert all(call["sampling"].max_tokens <= 128 for call in session.calls)


def test_the_deadline_pass_caps_itself_below_the_setting():
    """Two dates cannot need 4096 tokens, and a budget that large is only room
    to loop in."""
    items = [
        {"text": "One", "start": 1.0, "due": "by Friday"},
        {"text": "Two", "start": 2.0, "due": "tomorrow"},
    ]
    session = _session('{"dates":[]}')
    resolve_due_dates(session, items, "2026-07-26", sampling=SamplingParams(max_tokens=4096))

    assert session.calls[0]["sampling"].max_tokens == 60 + 40 * 2
