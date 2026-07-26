"""JSON stdin/stdout protocol shared by every command.

stdout is protocol-only: one JSON message per line
(progress / result / error / models). Anything else goes to stderr.
"""

from __future__ import annotations

import json


def emit(msg: dict) -> None:
    """Write one JSON message to stdout (for SwiftUI to read)."""
    print(json.dumps(msg, ensure_ascii=False), flush=True)  # noqa: T201 — the protocol itself
