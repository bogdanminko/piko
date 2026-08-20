"""What a prompt target is, and how a candidate for it becomes a model call.

One entry per system prompt the product ships. A target owns three things: the
placeholders a variant may use, how a case plus a variant text becomes the exact
messages `summarize()` would send, and what its schema is.

Everything here builds the *shipping* message, by importing the shipping code —
`_chunk_message`, `_notes_message`, `EXTRACT_SCHEMA`, `anchor_notes`. A harness
that reimplements the user turn measures the reimplementation. The only thing
this file substitutes is the system prompt, because that is the thing under test.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from piko.skills.meeting.summary import (
    DEFAULT_BUDGETS,
    DUE_SCHEMA,
    EXTRACT_SCHEMA,
    NOTES_RULES,
    SUMMARY_SCHEMA,
    Line,
    _chunk_message,
    _notes_message,
    anchor_notes,
    numbered_lines,
)

Message = dict[str, str]


@dataclass(frozen=True, slots=True)
class Built:
    """One model call, plus what scoring needs to know about it."""

    messages: list[Message]
    schema: dict[str, Any] | None
    #: Line numbers a citation is allowed to name. Empty where refs are not part
    #: of the task, which is not the same as "no line is valid" — see metrics.
    valid_refs: frozenset[int]
    lines: tuple[Line, ...] = ()


@dataclass(frozen=True, slots=True)
class Target:
    """A system prompt under test."""

    name: str
    #: Where the shipped text lives, so a winner can be applied without hunting.
    source: str
    #: Placeholders a variant is allowed to use. A variant may use fewer; using
    #: one that is not here fails loudly at format time, which is the point.
    placeholders: tuple[str, ...]
    #: Whether outputs go to the judge. `due` is arithmetic — a date either
    #: matches or it does not — so spending judgement on it would add noise.
    judged: bool = True
    notes: str = ""
    metrics: tuple[str, ...] = field(default_factory=tuple)


TARGETS: dict[str, Target] = {
    "extract": Target(
        name="extract",
        source="src/piko/skills/meeting/summary.py:EXTRACT_SYSTEM",
        placeholders=("language", "notes_rules"),
        notes="Map phase: one transcript chunk in, facts with citations out.",
        metrics=("refs", "owner_leak", "traps", "padding", "hedging"),
    ),
    "reduce": Target(
        name="reduce",
        source="src/piko/skills/meeting/summary.py:REDUCE_SYSTEM",
        placeholders=("brief", "summary", "topics", "language", "notes_rules"),
        notes="Reduce phase: partials in, the text a person actually reads out.",
        metrics=("refs", "budgets", "brief_echo", "padding", "hedging"),
    ),
    "due": Target(
        name="due",
        source="src/piko/skills/meeting/summary.py:DUE_SYSTEM",
        placeholders=(),
        judged=False,
        notes="Spoken deadline to a calendar date, anchored on the meeting day.",
        metrics=("dates",),
    ),
}


def render_system(target: str, variant_text: str, case: dict) -> str:
    """Fill a variant's placeholders the way the shipping code fills them."""
    values: dict[str, Any] = {}
    allowed = TARGETS[target].placeholders
    if "language" in allowed:
        values["language"] = case["output_language"]
    if "notes_rules" in allowed:
        # Same rule as the product: the block is present only when the call
        # actually carries notes, so nothing invites the model to invent a tag.
        values["notes_rules"] = NOTES_RULES if case.get("notes") else ""
    if "brief" in allowed:
        values["brief"] = DEFAULT_BUDGETS.brief_chars
    if "summary" in allowed:
        values["summary"] = DEFAULT_BUDGETS.summary_chars
    if "topics" in allowed:
        values["topics"] = DEFAULT_BUDGETS.topics
    return variant_text.format(**values)


def build(target: str, variant_text: str, case: dict) -> Built:
    """Case + candidate prompt → the messages a model will see."""
    system = render_system(target, variant_text, case)
    if target == "extract":
        return _build_extract(system, case)
    if target == "reduce":
        return _build_reduce(system, case)
    if target == "due":
        return _build_due(system, case)
    raise KeyError(f"unknown target {target!r}")


def _lines_of(case: dict) -> list[Line]:
    return numbered_lines(case["segments"], case.get("speakers"))


def _build_extract(system: str, case: dict) -> Built:
    """One chunk, whole. Cases are written to fit inside CHUNK_CHARS on purpose.

    Chunking is `chunk_lines`' job and it is already covered by unit tests; a
    prompt measured across two chunks would be measured against a merge it does
    not perform.
    """
    lines = _lines_of(case)
    typed = anchor_notes(case.get("notes") or (), lines)
    return Built(
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": _chunk_message(lines, case["output_language"], typed)},
        ],
        schema=EXTRACT_SCHEMA,
        valid_refs=frozenset(line.number for line in lines),
        lines=tuple(lines),
    )


def _build_reduce(system: str, case: dict) -> Built:
    """Partials in. The case supplies them rather than running extract first.

    Deliberate isolation: a reduce prompt scored on partials that a *different*
    prompt produced is being scored on that prompt's mistakes. Hand-written
    partials are also where the traps live — a padded decision list going in is
    how you find out whether a reduce prompt keeps the padding.
    """
    lines = _lines_of(case)
    typed = anchor_notes(case.get("notes") or (), lines)
    return Built(
        messages=[
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": _notes_message(case["partials"], case["output_language"], typed),
            },
        ],
        schema=SUMMARY_SCHEMA,
        valid_refs=frozenset(line.number for line in lines),
        lines=tuple(lines),
    )


def _build_due(system: str, case: dict) -> Built:
    """The deadline list, in the exact shape `resolve_due_dates` sends it."""
    listing = "\n".join(f'[{index}] "{phrase}"' for index, phrase in enumerate(case["deadlines"]))
    anchor = case["meeting_date"]
    weekday = case["meeting_weekday"]
    return Built(
        messages=[
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": (
                    f"<meeting_date>{anchor} ({weekday})</meeting_date>\n"
                    f"<language>{case['output_language']}</language>\n"
                    f"<deadlines>\n{listing}\n</deadlines>"
                ),
            },
        ],
        schema=DUE_SCHEMA,
        valid_refs=frozenset(),
    )
