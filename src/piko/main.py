"""Main entry point — reads JSON commands from stdin and dispatches them.

Protocol: one JSON command per line; handlers emit newline-delimited JSON
messages to stdout (see protocol.py).

The loop is deliberately backwards compatible with the original one-shot
contract. Swift writes a single compact JSON object and closes stdin
(BackendService.swift), which reads here as "one line, then EOF" — identical
behaviour to before. Keeping the process alive across several lines is what
makes a warm model possible: loading an LLM costs seconds and gigabytes
(bench/llm), so it has to outlive the command that triggered it. A caller that
holds stdin open can transcribe, warm the summarizer while the user reads the
transcript, and summarize, all against the same loaded weights.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterator

from .commands import HANDLERS
from .protocol import emit
from .watchdog import start as start_watchdog


def dispatch(line: str) -> None:
    """Run one command line. Never raises: every failure becomes an error message."""
    try:
        command = json.loads(line)
    except json.JSONDecodeError as e:
        emit({"type": "error", "message": f"Invalid JSON: {e}", "code": "JSON_ERROR"})
        return

    if not isinstance(command, dict):
        emit({"type": "error", "message": "Command must be a JSON object", "code": "JSON_ERROR"})
        return

    cmd = str(command.get("command"))
    handler = HANDLERS.get(cmd)
    if handler is None:
        emit({"type": "error", "message": f"Unknown command: {cmd}", "code": "UNKNOWN_COMMAND"})
        return

    try:
        handler(command.get("params", {}))
    except Exception as e:  # noqa: BLE001 — a crashed handler must not kill the session
        emit({"type": "error", "message": str(e), "code": type(e).__name__})


def _commands(stream: Iterator[str]) -> Iterator[str]:
    """Non-empty lines from stdin."""
    for raw in stream:
        line = raw.strip()
        if line:
            yield line


def main() -> None:
    # Don't outlive the app: exit (with children) once the parent is gone.
    start_watchdog()

    handled = 0
    try:
        for line in _commands(sys.stdin):
            dispatch(line)
            handled += 1
    finally:
        _shutdown()

    if handled == 0:
        emit({"type": "error", "message": "No input received", "code": "NO_INPUT"})


def _shutdown() -> None:
    """Free anything the session held open. Best-effort by design."""
    try:
        from .core.llm import pool

        pool.release()
    except Exception:  # noqa: BLE001,S110 — teardown must never emit noise
        pass


if __name__ == "__main__":
    main()
