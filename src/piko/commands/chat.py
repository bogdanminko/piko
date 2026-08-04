"""Free-form chat over the local model — how the workspace explains itself.

The point of this command is not conversation. It is that a first-time user
should be able to ask "what can this thing do?" and get an answer that is
*true*, rather than reading a feature list someone forgot to update. So the
system prompt below is a capability sheet, kept honest by being the only place
the answer comes from, and the model is told plainly to refuse what is not on
it — a local assistant inventing a feature is worse than one that says no.

The UI does not wait for this. It pseudo-streams a written answer immediately
and warms the model behind it (see `WorkspaceChatVM`), so the first reply costs
nothing even on a cold process.
"""

from __future__ import annotations

import time

from ..core.llm import Message
from ..core.llm import pool as llm_pool
from ..protocol import emit
from .reasoning import ReasoningFilter

# Everything Piko can actually do today, in the words the model should use.
# Add to this when a skill ships, not when one is planned: the failure mode
# this whole command exists to prevent is a confident answer about a feature
# that does not exist.
CAPABILITIES = """\
You are Piko, a local AI workspace that runs entirely on this Mac. Nothing the
user gives you is uploaded anywhere; there is no account, no API key and no
network call in any of the work you do.

The user can hand you a file by dropping it straight into this conversation or
with the paperclip beside the message box — so telling them to do that is
correct, and you should. You read what the file is (audio only, or long, means
a call; a short clip with a picture means something to caption) and start
without asking them to choose.

What you can actually do today, and nothing else:

1. Subtitles for a video. The user drops a video; you transcribe it locally,
   show the words with timecodes, and let them correct any line. From there
   they can save .srt, .vtt, .ass or plain text for free, or burn styled
   captions into a copy of the video (five looks: MrBeast, Hormozi, TikTok,
   Karaoke, Minimal). Burning re-encodes the whole video; the subtitle files
   cost nothing and are ready immediately.

2. Summarise a call. The user records a call (microphone and system audio are
   captured as separate tracks, so every line knows which side said it) or
   imports an existing recording. You produce a transcript with timecodes, a
   summary, decisions, action items with owners and deadlines where somebody
   said them out loud, open questions and key quotes. Every item links back to
   the moment in the audio it came from, so it can be checked.

3. Send the result somewhere. Action items export to Reminders or Calendar, to
   .ics or .csv files, or to a prefilled create-page for Jira, GitHub, GitLab,
   Linear, Trello, Todoist, Things or OmniFocus. Summaries export as Markdown.
   None of this needs a token or an account.

Things you cannot do, and must say so plainly when asked: editing video on a
timeline, cutting or reframing clips, generating images or voices, translating
subtitles, searching the web, reading files other than the recording you were
given, or anything that would send data off this machine.

Answer in the user's own language. Be short — two or three sentences unless
asked for detail. Never invent a feature: if it is not listed above, say Piko
cannot do it yet.
"""

# Slash commands the UI understands; described here so the model can suggest
# them rather than inventing syntax.
COMMAND_SHEET = """\
The user can also type slash commands: /captions to pick a video for
subtitles, /summarize to pick a recording to summarise, /record to start
recording a call, /library to browse past sessions, /help for this list.
"""

MAX_HISTORY = 12

# And how much of it, in characters.
#
# Turn count alone is not a budget. A turn can carry pasted material — the UI
# lets someone hand over a transcript with their question — and twelve of those
# is however much they pasted, which is unbounded. Spent newest-first: the
# question just asked is the one that must survive, and an older turn losing
# its tail costs less than the current one never arriving.
MAX_HISTORY_CHARS = 12_000

# How much of the open artifact goes into the prompt.
#
# A three-hour call is half a million characters and the local model has a few
# thousand tokens to think in, so this is a budget, not a limit we hope not to
# hit. Head and tail rather than the first N: a call's opening says what it is
# about and its closing says what was agreed, and the middle is the part you
# can most afford to lose.
MAX_ARTIFACT_CHARS = 12_000


def _fit(text: str, budget: int) -> str:
    """Trim to the budget, keeping both ends and saying where the cut is."""
    if len(text) <= budget:
        return text
    head = int(budget * 0.6)
    tail = budget - head
    return (
        text[:head].rstrip()
        + f"\n\n[… {len(text) - budget} characters omitted from the middle …]\n\n"
        + text[-tail:].lstrip()
    )


def _conversation(params: dict) -> list[Message]:
    """System sheet, what is currently loaded, then the recent turns."""
    history = params.get("messages") or []

    sheet = CAPABILITIES + "\n" + COMMAND_SHEET
    # Without this the model tells people to drop a file they dropped a minute
    # ago — the single most obvious way for an assistant to look like it is
    # not paying attention.
    context = (params.get("context") or "").strip()
    sheet += f"\nRight now: {context}\n" if context else "\nRight now: nothing is loaded.\n"

    # The artifact itself, not a description of it. Without this the model can
    # only talk *about* the transcript on screen — the user has to copy the
    # thing they are already looking at back into the box to ask a question
    # about it, which is the whole point of it being open in front of both of
    # them. The wording is narrow on purpose: answer from this, and say when it
    # does not contain the answer rather than filling the gap.
    artifact = (params.get("artifact") or "").strip()
    if artifact:
        sheet += (
            "\nThe user is looking at this. Answer from it and quote it where that "
            "helps. If it does not contain the answer, say so — do not fill the gap "
            "from anywhere else.\n\n"
            "--- begin artifact ---\n"
            f"{_fit(artifact, MAX_ARTIFACT_CHARS)}\n"
            "--- end artifact ---\n"
        )

    turns: list[Message] = [{"role": "system", "content": sheet}]

    # Only the tail, and only so much of it: this runs on a small local model,
    # and an unbounded transcript of the conversation costs context that the
    # answer needs more.
    recent: list[Message] = []
    left = MAX_HISTORY_CHARS
    for turn in reversed(history[-MAX_HISTORY:]):
        role = turn.get("role")
        content = (turn.get("content") or "").strip()
        if role not in ("user", "assistant") or not content:
            continue
        if left <= 0:
            break
        recent.append({"role": role, "content": _fit(content, left)})
        left -= len(content)
    turns.extend(reversed(recent))
    return turns


def handle_chat(params: dict) -> None:
    """Stream an answer about what Piko can do.

    The final `result` carries what the run cost. Two of the four numbers come
    from mlx-lm and two are wall-clock here, and the distinction matters:
    `prompt_tps` and `generation_tps` are the model's own rates, while time to
    first token and end-to-end include everything around it — loading a cold
    model, building the prompt, the protocol itself. Showing only the model's
    rates would report a fast machine on a run the user experienced as slow.
    """
    turns = _conversation(params)
    if len(turns) < 2:
        emit({"type": "error", "message": "No message to answer", "code": "EMPTY_CHAT"})
        return

    try:
        started = time.monotonic()
        session = llm_pool.acquire(params)
        parts: list[str] = []
        first_token_at: float | None = None
        last = None
        # A reasoning model thinks out loud before it answers, and that thinking
        # is protocol, not prose — see `reasoning.py` for what it looked like in
        # a bubble.
        answer = ReasoningFilter()
        thinking_announced = False
        with llm_pool.in_use():
            for chunk in session.stream(turns):
                last = chunk
                if not chunk.text:
                    continue
                visible = answer.feed(chunk.text)
                if answer.is_thinking and not thinking_announced:
                    # Said once, so the UI can show it is working rather than
                    # look hung for the seconds a long reasoning pass takes.
                    thinking_announced = True
                    emit({"type": "chat", "thinking": True})
                if visible:
                    if first_token_at is None:
                        first_token_at = time.monotonic()
                    parts.append(visible)
                    emit({"type": "chat", "delta": visible})
        finished = time.monotonic()
        stats = {
            "prompt_tokens": last.prompt_tokens if last else 0,
            "generation_tokens": last.generation_tokens if last else 0,
            "prompt_tps": round(last.prompt_tps, 1) if last and last.prompt_tps else None,
            "generation_tps": (
                round(last.generation_tps, 1) if last and last.generation_tps else None
            ),
            "ttft_seconds": (
                round(first_token_at - started, 2) if first_token_at is not None else None
            ),
            "total_seconds": round(finished - started, 2),
        }
        emit({"type": "result", "success": True, "message": "".join(parts), "stats": stats})
    except Exception as e:  # noqa: BLE001 — every provider failure reads the same here
        emit({"type": "error", "message": str(e), "code": type(e).__name__})
