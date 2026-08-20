"""What can be measured about an output without an opinion.

Everything here is arithmetic or string matching, and it runs before anything is
judged. That split is the point: a citation either names a line that exists or it
does not, and spending a judgement on that question would add noise to a fact.
What is left for the judge is the part that genuinely needs reading — whether the
text is true, complete, useful, and free of filler.

Two of these are gates rather than signals (see rubric.md): a variant that emits
an unparseable object, or that cites a line number nobody said, is not ranked at
all. The rest are evidence, reported to the judge and folded into reliability.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence
from typing import Any

from piko.core.llm import extract_json
from piko.skills.meeting.summary import DEFAULT_BUDGETS, detect_language

LIST_FIELDS = ("decisions", "action_items", "open_questions")

# Filler that says nothing about *this* meeting. Two families, counted apart
# because they fail differently: a hedge tells you the model is unsure and
# padding it out, vague-summary language tells you it summarized the *shape* of
# a meeting rather than its content ("the team discussed several topics" is true
# of every meeting ever held, which is what makes it worthless).
HEDGES = (
    "based on the transcript",
    "according to the transcript",
    "it appears that",
    "it seems that",
    "it should be noted",
    "it is important to note",
    "please note that",
    "as an ai",
    "i cannot determine",
    "судя по транскрипту",
    "согласно транскрипту",
    "по всей видимости",
    "стоит отметить",
    "важно отметить",
    "следует отметить",
)

VAGUE = (
    "various topics",
    "several topics",
    "a number of topics",
    "the team discussed",
    "the participants discussed",
    "there was a discussion",
    "next steps were discussed",
    "moving forward",
    "circle back",
    "touch base",
    "align on",
    "различные вопросы",
    "ряд вопросов",
    "участники обсудили",
    "в ходе обсуждения",
    "были рассмотрены",
    "дальнейшие шаги",
)


def measure(target: str, case: dict, raw_text: str, valid_refs: frozenset[int]) -> dict[str, Any]:
    """Everything measurable about one generation."""
    parsed = extract_json(raw_text)
    out: dict[str, Any] = {"json_ok": parsed is not None}
    if parsed is None:
        # A gate failure. Reporting the head of what did come back is what makes
        # the failure diagnosable — "did not parse" alone cannot be acted on.
        out["raw_head"] = raw_text[:200]
        return out

    if target == "due":
        out.update(_due(case, parsed))
        return out

    out.update(_shape(target, parsed))
    out.update(_refs(parsed, valid_refs))
    out.update(_owners(case, parsed))
    out.update(_traps(case, parsed))
    out.update(_counts(case, parsed))
    out.update(_language(case, parsed))
    out.update(_filler(parsed))
    if target == "reduce":
        out.update(_budgets(parsed))
    return out


# --- shape -----------------------------------------------------------------


def _required(target: str) -> tuple[str, ...]:
    base = ("topics", *LIST_FIELDS)
    if target == "extract":
        return ("notes", *base)
    return ("brief", "summary", *base)


def _shape(target: str, parsed: dict) -> dict[str, Any]:
    """Every required key present, and the lists actually lists."""
    missing = [key for key in _required(target) if key not in parsed]
    wrong = [
        key
        for key in ("topics", *LIST_FIELDS)
        if key in parsed and not isinstance(parsed[key], list)
    ]
    return {"keys_missing": missing, "keys_wrong_type": wrong, "shape_ok": not missing and not wrong}


def _items(parsed: dict, fields: Iterable[str] = LIST_FIELDS) -> list[Any]:
    """Every entry of the cited lists, malformed ones included.

    Deliberately not filtered to dicts. The first smoke run of this harness
    returned `open_questions` as bare strings, and a dict-only walk reported
    zero citations and zero bad ones — a clean bill of health for an output
    whose every question `_resolve` would drop on the way to the screen. What
    is silently discarded downstream has to be counted here or it is invisible
    everywhere.
    """
    out: list[Any] = []
    for field in fields:
        value = parsed.get(field)
        if isinstance(value, list):
            out.extend(value)
    return out


# --- citations -------------------------------------------------------------


def _refs(parsed: dict, valid: frozenset[int]) -> dict[str, Any]:
    """Every citation, split by how it fails — because the two failures differ.

    `refs_bad` is a citation that names a line nobody said. It is a gate: the
    product's promise is that an item can be clicked back to the second it came
    from, and one invented number breaks it. No amount of good prose buys that
    back, so a variant that produces one is not ranked.

    `refs_missing` is an item that carries no usable citation at all — a bare
    string where an object belongs, or an object with no "ref". Nothing is
    falsified; the item is simply dropped by `_resolve` before it reaches the
    screen. That costs coverage, not honesty, so it is scored rather than gated.
    """
    total = 0
    bad: list[Any] = []
    missing = 0
    for item in _items(parsed):
        total += 1
        if not isinstance(item, dict) or "ref" not in item:
            missing += 1
            continue
        ref = item["ref"]
        if not isinstance(ref, int) or isinstance(ref, bool) or ref not in valid:
            bad.append(ref)
    return {
        "refs_total": total,
        "refs_bad": len(bad),
        "refs_bad_values": bad[:10],
        "refs_missing": missing,
        "items_kept": total - len(bad) - missing,
    }


# --- owners ----------------------------------------------------------------


def _owners(case: dict, parsed: dict) -> dict[str, Any]:
    """Speaker labels leaking into `owner`, and owners nobody in the room is.

    "Participants" is who spoke, not who owns the task. `_resolve` strips those
    in production, which means a prompt that leaks them looks fine on screen —
    the cost is that every task from a call where nobody was named comes out
    ownerless, and that failure is invisible unless it is measured here.
    """
    labels = {name.casefold() for name in (case.get("speakers") or {}).values()}
    known = {name.casefold() for name in case.get("key", {}).get("people", [])}
    leaked: list[str] = []
    unknown: list[str] = []
    for item in _items(parsed, ("action_items",)):
        owner = item.get("owner") if isinstance(item, dict) else None
        if not isinstance(owner, str) or not owner.strip():
            continue
        folded = owner.strip().casefold()
        if folded in labels:
            leaked.append(owner.strip())
        elif known and not any(name in folded or folded in name for name in known):
            unknown.append(owner.strip())
    return {"owner_leaks": leaked, "owner_unknown": unknown}


# --- traps -----------------------------------------------------------------


def _traps(case: dict, parsed: dict) -> dict[str, Any]:
    """Case-defined bait: a thing that must not appear in a given field.

    Every trap is something the transcript deliberately makes tempting — an idea
    somebody floated but nobody settled, a name that was never in the room. The
    check is a substring on that field only, because "Postgres" belongs in the
    topics of a meeting where Postgres was discussed and does not belong in its
    decisions.
    """
    hits: list[dict[str, Any]] = []
    for trap in case.get("key", {}).get("traps", []):
        field = trap["field"]
        haystack = " ".join(_texts_of(parsed, field)).casefold()
        for needle in trap["forbid"]:
            if needle.casefold() in haystack:
                hits.append({"id": trap["id"], "field": field, "matched": needle})
                break
    return {"trap_hits": hits, "traps_total": len(case.get("key", {}).get("traps", []))}


def _texts_of(parsed: dict, field: str) -> list[str]:
    """Every string a field contains, whatever shape that field has."""
    value = parsed.get(field)
    if isinstance(value, str):
        return [value]
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            out.extend(str(v) for v in item.values() if isinstance(v, str))
    return out


# --- padding ---------------------------------------------------------------


def _counts(case: dict, parsed: dict) -> dict[str, Any]:
    """List sizes against what the case says the meeting actually contains.

    `expect_empty` is the sharpest instrument in the whole harness. A call where
    nothing was decided is the case that separates a prompt that reports from a
    prompt that performs: the honest answer is an empty list, and the tempting
    one is three sentences that look like decisions.
    """
    key = case.get("key", {})
    counts = {
        field: len(parsed[field]) if isinstance(parsed.get(field), list) else None
        for field in ("topics", *LIST_FIELDS)
    }
    padded = [field for field in key.get("expect_empty", []) if (counts.get(field) or 0) > 0]
    over: list[str] = []
    under: list[str] = []
    for field, bounds in key.get("expect_counts", {}).items():
        low, high = bounds
        got = counts.get(field)
        if got is None:
            continue
        if got > high:
            over.append(f"{field}={got}>{high}")
        elif got < low:
            under.append(f"{field}={got}<{low}")
    return {
        "counts": counts,
        "padded_empty": padded,
        "count_over": over,
        "count_under": under,
    }


# --- language --------------------------------------------------------------


_CYRILLIC = re.compile(r"[Ѐ-ӿ]")


def _language(case: dict, parsed: dict) -> dict[str, Any]:
    """Did it answer in the transcript's language, or in the prompt's?

    The failure this catches is specific and common below 4B: an English system
    prompt over a Russian transcript pulls the answer into English. Script
    settles Russian outright; for the Latin languages `detect_language` needs a
    page of text and a short summary may not give it one, so an undecided
    reading is not counted as a failure — the judge sees the text anyway.
    """
    text = " ".join(_all_text(parsed))
    expected = case["lang"]
    if not text.strip():
        return {"lang_detected": None, "lang_ok": False}
    if expected == "ru":
        letters = [char for char in text if char.isalpha()]
        ratio = len(_CYRILLIC.findall(text)) / max(len(letters), 1)
        return {"lang_detected": "ru" if ratio > 0.5 else "other", "lang_ok": ratio > 0.5}
    detected = detect_language(text)
    return {"lang_detected": detected, "lang_ok": detected in (None, expected)}


def _all_text(parsed: dict) -> list[str]:
    out: list[str] = []
    for field in ("notes", "brief", "summary"):
        value = parsed.get(field)
        if isinstance(value, str):
            out.append(value)
    for field in ("topics", *LIST_FIELDS):
        out.extend(_texts_of(parsed, field))
    return out


# --- filler ----------------------------------------------------------------


def _filler(parsed: dict) -> dict[str, Any]:
    """Hedging and contentless phrasing, counted rather than argued about."""
    text = " ".join(_all_text(parsed)).casefold()
    hedges = [phrase for phrase in HEDGES if phrase in text]
    vague = [phrase for phrase in VAGUE if phrase in text]
    return {"hedges": hedges, "vague": vague}


# --- budgets (reduce only) -------------------------------------------------


def _budgets(parsed: dict) -> dict[str, Any]:
    """Does it fit the cards, and is the long read actually a different text?

    `brief_echo` is the one that matters. REDUCE asks for a brief and a long
    summary, and the cheapest way to satisfy both is to write the brief twice —
    which passes every other check here and gives the reader nothing for the
    second card.
    """
    brief = str(parsed.get("brief", ""))
    summary = str(parsed.get("summary", ""))
    over = []
    if len(brief) > DEFAULT_BUDGETS.brief_chars:
        over.append(f"brief={len(brief)}")
    if len(summary) > DEFAULT_BUDGETS.summary_chars:
        over.append(f"summary={len(summary)}")
    if len(parsed.get("topics", []) or []) > DEFAULT_BUDGETS.topics:
        over.append(f"topics={len(parsed['topics'])}")
    return {
        "brief_chars": len(brief),
        "summary_chars": len(summary),
        "over_budget": over,
        "brief_echo": _echo(brief, summary),
        "summary_ratio": round(len(summary) / len(brief), 2) if brief else None,
    }


def _echo(brief: str, summary: str) -> float:
    """Share of the brief's sentences that turn up near-verbatim in the summary."""
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", brief) if len(s.strip()) > 20]
    if not sentences:
        return 0.0
    body = _normalize(summary)
    return round(sum(1 for s in sentences if _normalize(s) in body) / len(sentences), 2)


def _normalize(text: str) -> str:
    return re.sub(r"\W+", " ", text.casefold()).strip()


# --- due dates -------------------------------------------------------------


def _due(case: dict, parsed: dict) -> dict[str, Any]:
    """Exact-match scoring. No judgement needed: a date is right or it is not.

    The two errors are not equal and are counted apart. A missed date costs the
    user a field they can type; an *invented* one puts a deadline nobody agreed
    to into their Reminders, which is the failure the null-over-guess rule in
    resolve_due_dates exists to prevent.
    """
    answers = {
        entry["index"]: entry
        for entry in parsed.get("dates", [])
        if isinstance(entry, dict) and isinstance(entry.get("index"), int)
    }
    right = invented = missed = wrong = 0
    detail: list[dict[str, Any]] = []
    for expected in case["key"]["expected"]:
        index = expected["index"]
        got = answers.get(index, {})
        got_date = got.get("date") if isinstance(got.get("date"), str) else None
        got_time = got.get("time") if isinstance(got.get("time"), str) else None
        want_date, want_time = expected["date"], expected.get("time")
        # Time is matched as strictly as the date, including both being absent.
        # "by Friday" answered as Friday 17:00 has invented a commitment nobody
        # made, and it reaches Reminders looking exactly like one that was.
        if got_date == want_date and got_time == want_time:
            right += 1
            outcome = "right"
        elif want_date is None and got_date is not None:
            invented += 1
            outcome = "invented"
        elif want_date is not None and got_date is None:
            missed += 1
            outcome = "missed"
        else:
            wrong += 1
            outcome = "wrong"
        detail.append(
            {
                "index": index,
                "phrase": case["deadlines"][index],
                "want": want_date,
                "got": got_date,
                "outcome": outcome,
            }
        )
    total = len(case["key"]["expected"])
    return {
        "due_total": total,
        "due_right": right,
        "due_invented": invented,
        "due_missed": missed,
        "due_wrong": wrong,
        "due_accuracy": round(right / total, 3) if total else None,
        "due_detail": detail,
    }


# --- rollup ----------------------------------------------------------------


def gates_passed(rows: Sequence[dict]) -> dict[str, Any]:
    """The three hard conditions, over every run of one variant on one tier.

    Lexicographic rather than folded into the weighted score on purpose: a
    multi-objective sum lets a fluent prompt buy back an invented citation with
    good prose, and there is no exchange rate at which that trade is acceptable
    for this product. Cheap to state, and it keeps the leaderboard honest.
    """
    if not rows:
        return {"parse_rate": 0.0, "refs_bad": 0, "lang_rate": 0.0, "fit": False}
    parse = sum(1 for row in rows if row["metrics"].get("json_ok")) / len(rows)
    parsed = [row["metrics"] for row in rows if row["metrics"].get("json_ok")]
    bad_refs = sum(m.get("refs_bad", 0) for m in parsed)
    lang = (
        sum(1 for m in parsed if m.get("lang_ok", True)) / len(parsed)
        if parsed
        else 0.0
    )
    return {
        "parse_rate": round(parse, 3),
        "refs_bad": bad_refs,
        "lang_rate": round(lang, 3),
        "fit": parse >= 0.95 and bad_refs == 0 and lang >= 0.999,
    }
