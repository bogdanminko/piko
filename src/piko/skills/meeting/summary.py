"""Transcript → structured summary, with every claim tied to a timecode.

Shape of the run: the transcript is cut into chunks, each chunk is extracted
independently (batched — one forward pass over all of them on the embedded
backend), and the partials are merged into the final result. Long meetings
therefore cost several model calls, not one.

**Timecodes are never generated.** Asking a model for "12:40" produces
plausible fiction, which is exactly the failure PRODUCT.md's verifiability
promise cannot survive. Instead every transcript line is numbered, the model
cites a line number in `ref`, and this module resolves that number back to the
second it starts at. A citation that does not resolve is dropped rather than
guessed — a summary with fewer items is honest, one with invented timecodes is
not.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from ...core.llm import (
    LLMSession,
    Message,
    SamplingParams,
    StructuredOutputError,
    extract_json,
)

# Roughly how many characters of transcript go into one extraction call.
# Deliberately conservative: Cyrillic costs ~2 characters per token where
# Latin costs ~4, so a budget that is safe for Russian is generous for English.
CHUNK_CHARS = 6000
# Carried into the next chunk so a decision stated across a boundary is not
# lost by either side.
CHUNK_OVERLAP_CHARS = 600


@dataclass(frozen=True, slots=True)
class Budgets:
    """What the summary cards can actually show without overflowing.

    Enforced after generation (see `_fit`): a model that writes an essay gets
    asked again for a shorter one, and is finally truncated. The numbers come
    from the card layout in Piko/Views/MeetingSummaryPreviewCards.swift.
    """

    brief_chars: int = 400
    summary_chars: int = 2000
    topics: int = 6
    decisions: int = 8
    action_items: int = 10
    open_questions: int = 6


DEFAULT_BUDGETS = Budgets()

# --- prompts --------------------------------------------------------------
#
# One system prompt per task. Both are short and XML-tagged: the tags survive
# a long transcript in the same context far better than prose instructions,
# which small models drift away from once the input dominates the window.

EXTRACT_SYSTEM = """\
You extract facts from one part of a meeting transcript.

<rules>
- Use only what the transcript states. Never invent people, dates or decisions.
- Every item must cite the number of the line it came from, in "ref".
- "notes" is 1-2 sentences on what this part of the meeting was about, and is
  the only field that may narrate rather than list.
- "owner" is a person named in the transcript, never a speaker label. Set
  "owner" and "due" to null unless someone actually states them.
- A decision is a settled choice, not a proposal under discussion.
- An open question is one raised and left unanswered here.
- Write every field in {language}, including topics, whatever language these
  instructions are in.
- Leave a list empty rather than padding it with weak items.
</rules>

<output>A single JSON object. No prose, no code fence.</output>"""

REDUCE_SYSTEM = """\
You merge notes extracted from one meeting into its final summary.

<rules>
- Merge duplicates: one decision stated twice is one item, keeping the lowest "ref".
- Copy every "ref" exactly as given. Never invent, renumber or shift one.
- "brief" is 2-3 sentences on what the meeting settled, at most {brief} characters.
- "summary" is the long read, built from <notes>: how the discussion actually
  went, in order, in several paragraphs, at most {summary} characters. It must
  be substantially longer than "brief" and must not repeat its wording.
- "topics" are {topics} or fewer short noun phrases, not sentences.
- Order every list by "ref", ascending.
- Write every field in {language}, including topics, whatever language these
  instructions are in.
</rules>

<output>A single JSON object. No prose, no code fence.</output>"""

SHORTEN_SYSTEM = """\
You shorten a meeting summary that does not fit its display.

<rules>
- Keep the same JSON shape, the same language, and every "ref" unchanged.
- Drop the least important items; never rewrite the ones you keep beyond trimming.
- "brief" at most {brief} characters, "summary" at most {summary} characters.
- Keep the text in {language}.
- Keep at most {topics} topics, {decisions} decisions, {action_items} action items,
  {open_questions} open questions.
</rules>

<output>A single JSON object. No prose, no code fence.</output>"""

_REF = {"type": "integer", "description": "Transcript line number this came from"}

EXTRACT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "notes": {
            "type": "string",
            "description": "1-2 sentences on what this part of the meeting covered",
        },
        "topics": {"type": "array", "items": {"type": "string"}},
        "decisions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "ref": _REF},
                "required": ["text", "ref"],
            },
        },
        "action_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "owner": {"type": ["string", "null"]},
                    "due": {"type": ["string", "null"]},
                    "ref": _REF,
                },
                "required": ["text", "ref"],
            },
        },
        "open_questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "ref": _REF},
                "required": ["text", "ref"],
            },
        },
    },
    "required": ["notes", "topics", "decisions", "action_items", "open_questions"],
}

SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "brief": {"type": "string"},
        "summary": {"type": "string"},
        **{key: value for key, value in EXTRACT_SCHEMA["properties"].items() if key != "notes"},
    },
    "required": ["brief", "summary", "topics", "decisions", "action_items", "open_questions"],
}

_LIST_FIELDS = ("decisions", "action_items", "open_questions")

# ASR gives us the language already, so the prompts can name it outright.
_LANGUAGE_NAMES = {
    "ru": "Russian",
    "en": "English",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "it": "Italian",
    "pt": "Portuguese",
    "nl": "Dutch",
    "pl": "Polish",
    "uk": "Ukrainian",
    "tr": "Turkish",
    "zh": "Chinese",
    "ja": "Japanese",
    "ko": "Korean",
}


# Words common enough to identify a Latin-script language from a page of
# speech. Cyrillic and CJK are settled by script alone, above.
# Deliberately words that are *distinctive*, not merely frequent: "in" and
# "de" are common in several of these languages and would blur the counts.
_STOPWORDS = {
    "en": {
        "the",
        "and",
        "that",
        "with",
        "this",
        "for",
        "you",
        "have",
        "not",
        "will",
        "are",
        "was",
        "they",
        "from",
        "been",
        "would",
        "should",
    },
    "de": {
        "und",
        "die",
        "der",
        "das",
        "nicht",
        "ist",
        "wir",
        "mit",
        "auch",
        "aber",
        "haben",
        "werden",
        "eine",
        "sich",
        "noch",
    },
    "fr": {
        "les",
        "des",
        "que",
        "pour",
        "dans",
        "est",
        "une",
        "nous",
        "pas",
        "avec",
        "avons",
        "sont",
        "mais",
        "cette",
        "faire",
    },
    "es": {
        "que",
        "los",
        "las",
        "por",
        "para",
        "con",
        "una",
        "esta",
        "pero",
        "hacer",
        "tiene",
        "sobre",
        "cuando",
    },
    "it": {
        "che",
        "non",
        "per",
        "una",
        "sono",
        "come",
        "anche",
        "questo",
        "abbiamo",
        "della",
        "nella",
        "quando",
    },
    "pt": {
        "que",
        "para",
        "com",
        "uma",
        "não",
        "isso",
        "mas",
        "está",
        "temos",
        "fazer",
        "sobre",
        "quando",
    },
}


def detect_language(text: str) -> str | None:
    """Guess the language of a transcript when ASR did not report one.

    Parakeet infers language from audio but returns no code, so a real
    recording arrives as "unknown" — and an unnamed target language is exactly
    what makes a 4B model answer in the language of its English prompt instead
    of the transcript's. Script settles the non-Latin cases; a stopword count
    settles the rest. Returns None when nothing wins, and the caller falls back
    to the vaguer instruction.
    """
    sample = text[:20000]
    if not sample.strip():
        return None

    letters = [char for char in sample if char.isalpha()]
    if not letters:
        return None
    cyrillic = sum(1 for char in letters if "\u0400" <= char <= "\u04ff")
    if cyrillic / len(letters) > 0.2:
        # Ukrainian has letters Russian does not; everything else Cyrillic here
        # is overwhelmingly Russian.
        return "uk" if any(char in sample for char in "їієґ") else "ru"
    if any("\u4e00" <= char <= "\u9fff" for char in sample):
        return "zh"
    if any("\u3040" <= char <= "\u30ff" for char in sample):
        return "ja"
    if any("\uac00" <= char <= "\ud7af" for char in sample):
        return "ko"

    words = set(re.findall(r"[a-zà-ÿ]+", sample.casefold()))
    scores = {code: len(words & stops) for code, stops in _STOPWORDS.items()}
    best = max(scores, key=lambda code: scores[code])
    return best if scores[best] >= 3 else None


def offered_languages() -> list[dict[str, str]]:
    """Languages the UI can offer for the summary, plus the automatic option.

    An empty code means "same as the recording", which keeps zero-setup intact:
    nobody has to choose anything before their first summary.
    """
    return [{"code": "", "name": "Same as the recording"}] + [
        {"code": code, "name": name}
        for code, name in sorted(_LANGUAGE_NAMES.items(), key=lambda pair: pair[1])
    ]


def language_name(code: str | None) -> str:
    """ISO code → the name to put in a prompt; unknown codes pass through."""
    if not code or code == "unknown":
        return "the language of the transcript"
    return _LANGUAGE_NAMES.get(code.lower()[:2], code)


@dataclass(frozen=True, slots=True)
class Line:
    """One numbered transcript line — the unit a citation can point at."""

    number: int
    start: float
    speaker: str
    text: str

    def render(self) -> str:
        return f"[{self.number}] {self.speaker}: {self.text}"


def numbered_lines(segments: Sequence[dict], speakers: dict[str, str] | None = None) -> list[Line]:
    """Transcript segments → numbered lines, skipping empty ones."""
    speakers = speakers or {}
    lines: list[Line] = []
    for segment in segments:
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        key = str(segment.get("speaker", "")) or "unknown"
        lines.append(
            Line(
                number=len(lines) + 1,
                start=float(segment.get("start", 0.0)),
                speaker=speakers.get(key, key.title()),
                text=text,
            )
        )
    return lines


def chunk_lines(
    lines: Sequence[Line],
    budget_chars: int = CHUNK_CHARS,
    overlap_chars: int = CHUNK_OVERLAP_CHARS,
) -> list[list[Line]]:
    """Group lines into chunks under `budget_chars`, overlapping at the seams.

    Splits only between lines, never inside one, so a citation always points at
    a line that was shown whole.
    """
    if not lines:
        return []

    chunks: list[list[Line]] = []
    current: list[Line] = []
    size = 0
    for line in lines:
        rendered = len(line.render()) + 1
        if current and size + rendered > budget_chars:
            chunks.append(current)
            # Re-show the tail of the previous chunk.
            carried: list[Line] = []
            carried_size = 0
            for previous in reversed(current):
                carried_size += len(previous.render()) + 1
                if carried_size > overlap_chars:
                    break
                carried.insert(0, previous)
            current, size = carried, carried_size
        current.append(line)
        size += rendered
    if current:
        chunks.append(current)
    return chunks


def _chunk_message(chunk: Sequence[Line], language: str) -> str:
    body = "\n".join(line.render() for line in chunk)
    return f"<language>{language}</language>\n<transcript>\n{body}\n</transcript>"


def _notes_message(partials: Sequence[dict], language: str) -> str:
    lines: list[str] = [f"<language>{language}</language>"]
    narration = [
        str(partial["notes"]).strip()
        for partial in partials
        if str(partial.get("notes", "")).strip()
    ]
    if narration:
        joined = "\n".join(f"- {note}" for note in narration)
        lines.append(f"<notes>\n{joined}\n</notes>")
    for field in ("topics", *_LIST_FIELDS):
        items: list[str] = []
        for partial in partials:
            for item in partial.get(field, []):
                if field == "topics":
                    items.append(str(item))
                else:
                    ref = item.get("ref")
                    owner = item.get("owner")
                    due = item.get("due")
                    extra = "".join(
                        part
                        for part in (
                            f" owner={owner}" if owner else "",
                            f" due={due}" if due else "",
                        )
                    )
                    items.append(f"[{ref}] {item.get('text', '')}{extra}")
        if items:
            joined = "\n".join(f"- {item}" for item in items)
            lines.append(f"<{field}>\n{joined}\n</{field}>")
    return "\n".join(lines) or "<notes>empty</notes>"


def _resolve(
    items: Sequence[dict], starts: dict[int, float], speaker_labels: frozenset[str] = frozenset()
) -> list[dict]:
    """Turn `ref` line numbers into seconds, dropping citations that do not resolve."""
    resolved: list[dict] = []
    for item in items:
        text = str(item.get("text", "")).strip()
        ref = item.get("ref")
        if not text or not isinstance(ref, int) or ref not in starts:
            continue
        entry = {"text": text, "start": starts[ref]}
        for optional in ("owner", "due"):
            value = item.get(optional)
            if not isinstance(value, str) or not value.strip():
                continue
            # "Participants" is who spoke, not who owns the task. The prompt
            # says so too, but a small model leaks the label often enough that
            # this has to be enforced here.
            if optional == "owner" and value.strip().casefold() in speaker_labels:
                continue
            entry[optional] = value.strip()
        resolved.append(entry)
    resolved.sort(key=lambda item: item["start"])
    return _dedupe(resolved)


def _dedupe(items: Sequence[dict]) -> list[dict]:
    """Drop repeats the model kept across overlapping chunks, earliest wins."""
    seen: set[str] = set()
    unique: list[dict] = []
    for item in items:
        key = re.sub(r"\W+", " ", item["text"].casefold()).strip()
        if key and key not in seen:
            seen.add(key)
            unique.append(item)
    return unique


def _over_budget(result: dict, budgets: Budgets) -> bool:
    return (
        len(result.get("brief", "")) > budgets.brief_chars
        or len(result.get("summary", "")) > budgets.summary_chars
        or len(result.get("topics", [])) > budgets.topics
        or len(result.get("decisions", [])) > budgets.decisions
        or len(result.get("action_items", [])) > budgets.action_items
        or len(result.get("open_questions", [])) > budgets.open_questions
    )


def _truncate(result: dict, budgets: Budgets) -> dict:
    """Last resort after the model has been asked twice: cut deterministically.

    Text is cut at a sentence end where one is near, so a trimmed brief reads
    as finished rather than as having been guillotined.
    """
    result["brief"] = _clip(result.get("brief", ""), budgets.brief_chars)
    result["summary"] = _clip(result.get("summary", ""), budgets.summary_chars)
    result["topics"] = list(result.get("topics", []))[: budgets.topics]
    result["decisions"] = list(result.get("decisions", []))[: budgets.decisions]
    result["action_items"] = list(result.get("action_items", []))[: budgets.action_items]
    result["open_questions"] = list(result.get("open_questions", []))[: budgets.open_questions]
    return result


def _clip(text: str, limit: int) -> str:
    """Cut to `limit` characters *including* the ellipsis, at a sentence end if near."""
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    return (cut[: end + 1] if end > limit * 0.6 else cut.rstrip()) + "…"


def summarize(
    session: LLMSession,
    segments: Sequence[dict],
    *,
    speakers: dict[str, str] | None = None,
    language: str | None = None,
    output_language: str | None = None,
    budgets: Budgets = DEFAULT_BUDGETS,
    on_progress: Callable[[str, float], None] | None = None,
) -> dict:
    """Run the whole pipeline and return a summary the UI can render directly.

    Raises StructuredOutputError only if the reduce step never produces JSON;
    a chunk that fails extraction is skipped, because losing one part of a
    meeting is better than losing the summary.
    """
    lines = numbered_lines(segments, speakers)
    if not lines:
        raise StructuredOutputError("Transcript has no usable lines to summarize")

    starts = {line.number: line.start for line in lines}
    chunks = chunk_lines(lines)
    # An explicit choice wins outright; it is also the only way to ask for a
    # summary in a language the meeting was not held in.
    code = output_language or None
    if code is None:
        code = language if language and language != "unknown" else None
    if code is None:
        code = detect_language(" ".join(line.text for line in lines))
    target_language = language_name(code)
    labels = frozenset(name.casefold() for name in (speakers or {}).values())

    def report(stage: str, percent: float) -> None:
        if on_progress is not None:
            on_progress(stage, percent)

    report("extracting", 5)
    conversations: list[list[Message]] = [
        [
            {
                "role": "system",
                "content": EXTRACT_SYSTEM.format(language=target_language),
            },
            {"role": "user", "content": _chunk_message(chunk, target_language)},
        ]
        for chunk in chunks
    ]
    results = session.generate_batch(
        conversations,
        sampling=SamplingParams(max_tokens=900),
        json_schema=EXTRACT_SCHEMA,
        on_done=lambda done: report("extracting", 5 + 60 * done / max(len(chunks), 1)),
    )

    partials = [parsed for result in results if (parsed := extract_json(result.text)) is not None]
    if not partials:
        raise StructuredOutputError(
            f"{session.description} extracted nothing usable from {len(chunks)} chunk(s)"
        )

    report("summarizing", 70)
    merged = session.generate_json(
        [
            {
                "role": "system",
                "content": REDUCE_SYSTEM.format(
                    brief=budgets.brief_chars,
                    summary=budgets.summary_chars,
                    topics=budgets.topics,
                    language=target_language,
                ),
            },
            {"role": "user", "content": _notes_message(partials, target_language)},
        ],
        SUMMARY_SCHEMA,
        sampling=SamplingParams(max_tokens=1600),
    )

    # Backoff on length: ask once for a shorter version, then cut ourselves.
    if _over_budget(merged, budgets):
        report("shortening", 90)
        try:
            merged = session.generate_json(
                [
                    {
                        "role": "system",
                        "content": SHORTEN_SYSTEM.format(
                            brief=budgets.brief_chars,
                            summary=budgets.summary_chars,
                            topics=budgets.topics,
                            decisions=budgets.decisions,
                            action_items=budgets.action_items,
                            open_questions=budgets.open_questions,
                            language=target_language,
                        ),
                    },
                    {"role": "user", "content": _notes_message([merged], target_language)},
                ],
                SUMMARY_SCHEMA,
                sampling=SamplingParams(max_tokens=1400),
                retries=0,
            )
        except StructuredOutputError:
            pass  # keep the long version; truncation below still makes it fit

    report("summarizing", 96)
    result = {
        "brief": str(merged.get("brief", "")).strip(),
        "summary": str(merged.get("summary", "")).strip(),
        "topics": [str(topic).strip() for topic in merged.get("topics", []) if str(topic).strip()],
        **{field: _resolve(merged.get(field, []), starts, labels) for field in _LIST_FIELDS},
    }
    return _truncate(result, budgets)
