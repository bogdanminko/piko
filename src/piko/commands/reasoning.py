"""Keeping a model's thinking out of the chat bubble.

Reasoning models do not answer, they think out loud and *then* answer. For a
summary that costs nothing, because `extract_json` reads past the reasoning on
its way to the object. A chat streams raw text, and nothing read past anything —
so choosing the `max` tier put this in the conversation, verbatim:

    <|channel|>analysis<|message|>Need to answer: yes, Piko can burn
    subtitles.<|end|><|start|>assistant<|channel|>final<|message|>Yes, Piko
    can burn subtitles into a video copy…

Both halves of that are wrong to show. The markup is protocol the user has no
business seeing, and the analysis is the model talking to itself — presenting it
as the answer is presenting a draft as a decision.

The rule is deliberately narrow: hold back only a reply that *opens* with a
known reasoning marker, and only until the matching end marker arrives. A model
that never reasons streams from the first token, because buffering it while
waiting for an end that never comes would turn a working answer into a hang.
"""

from __future__ import annotations

from ..core.llm import REASONING_ENDS, REASONING_STARTS


class ReasoningFilter:
    """Feed it chunks; it hands back only what belongs in the answer.

    Stateful because the decision is: the first tokens decide whether this reply
    is reasoning at all, and after the end marker every later chunk passes
    straight through — re-scanning the whole reply per token would make a long
    answer quadratic for a question already settled.
    """

    def __init__(self) -> None:
        self._buffer = ""
        #: None until the opening tokens say which kind of reply this is.
        self._reasoning: bool | None = None
        self._done = False

    @property
    def is_thinking(self) -> bool:
        """Reasoning is being held back and no answer has started yet."""
        return self._reasoning is True and not self._done

    def feed(self, chunk: str) -> str:
        """The part of `chunk` that belongs in the answer. Often empty."""
        if self._done:
            return chunk

        self._buffer += chunk

        if self._reasoning is None:
            self._reasoning = self._opens_reasoning(self._buffer)
            if self._reasoning is None:
                # Not enough text yet to tell a marker from a prefix of one.
                return ""
            if not self._reasoning:
                self._done = True
                return self._buffer

        for marker in REASONING_ENDS:
            index = self._buffer.find(marker)
            if index >= 0:
                self._done = True
                return self._buffer[index + len(marker) :]
        return ""

    @staticmethod
    def _opens_reasoning(text: str) -> bool | None:
        """True, False, or None while the text is still shorter than a marker.

        The None is the point: deciding on the first token would call every
        reply that begins with "<" reasoning, and deciding never would let the
        first fragment of a `<think>` through before the rest arrived.
        """
        stripped = text.lstrip()
        if any(stripped.startswith(start) for start in REASONING_STARTS):
            return True
        if any(start.startswith(stripped) for start in REASONING_STARTS) and stripped:
            return None
        return False
