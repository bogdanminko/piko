"""Main entry point — reads one JSON command from stdin and dispatches.

Protocol: Swift writes {"command": ..., "params": {...}} to stdin;
handlers emit newline-delimited JSON messages to stdout (see protocol.py).
"""

from __future__ import annotations

import json
import sys

from .commands import HANDLERS
from .protocol import emit


def main() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        emit({"type": "error", "message": "No input received", "code": "NO_INPUT"})
        return

    try:
        command = json.loads(raw)
    except json.JSONDecodeError as e:
        emit({"type": "error", "message": f"Invalid JSON: {e}", "code": "JSON_ERROR"})
        return

    cmd = command.get("command")
    handler = HANDLERS.get(cmd)
    if handler:
        handler(command.get("params", {}))
    else:
        emit({"type": "error", "message": f"Unknown command: {cmd}", "code": "UNKNOWN_COMMAND"})


if __name__ == "__main__":
    main()
