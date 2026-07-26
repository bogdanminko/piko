"""Protocol contract tests.

The JSON protocol lives in two places that must stay in sync:
Python emit() call sites and the Swift BackendMessage struct
(Piko/Models/BackendMessage.swift). These tests catch drift without
running the app.
"""

import ast
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BACKEND_SRC = REPO / "src" / "piko"
SWIFT_MESSAGE = REPO / "Piko" / "Models" / "BackendMessage.swift"


def _emitted_keys() -> set[str]:
    """Collect literal dict keys passed to emit() anywhere in the backend."""
    keys: set[str] = set()
    for py in BACKEND_SRC.rglob("*.py"):
        tree = ast.parse(py.read_text(), filename=str(py))
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "emit"
                and node.args
                and isinstance(node.args[0], ast.Dict)
            ):
                for key in node.args[0].keys:
                    if isinstance(key, ast.Constant) and isinstance(key.value, str):
                        keys.add(key.value)
    return keys


def _swift_coding_keys() -> set[str]:
    """Parse raw JSON keys from BackendMessage's CodingKeys enum."""
    text = SWIFT_MESSAGE.read_text()
    match = re.search(r"struct BackendMessage.*?enum CodingKeys[^{]*\{(.*?)\}", text, re.DOTALL)
    assert match, "CodingKeys enum not found in BackendMessage.swift"
    body = match.group(1)

    keys: set[str] = set()
    for case_match in re.finditer(r"case\s+(.+)", body):
        for entry in case_match.group(1).split(","):
            entry = entry.strip()
            if not entry:
                continue
            renamed = re.match(r'\w+\s*=\s*"([^"]+)"', entry)
            keys.add(renamed.group(1) if renamed else entry)
    return keys


def test_emitted_keys_decodable_by_swift():
    """Every key the backend emits must exist in Swift's CodingKeys,
    otherwise Swift silently drops the field."""
    emitted = _emitted_keys()
    swift = _swift_coding_keys()

    assert emitted, "no emit() call sites found — extraction broken?"
    missing = emitted - swift
    assert not missing, (
        f"backend emits keys Swift cannot decode: {sorted(missing)} — "
        f"add them to BackendMessage.swift (CodingKeys + field)"
    )


def _run_backend(payload: str) -> list[str]:
    result = subprocess.run(
        [sys.executable, "-m", "piko.main"],
        input=payload,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def test_stdout_is_json_only_on_error_path():
    """Unknown command → exactly one well-formed error message, nothing else."""
    lines = _run_backend('{"command": "definitely_not_a_command"}')
    assert len(lines) == 1
    msg = json.loads(lines[0])
    assert msg["type"] == "error"
    assert msg["code"] == "UNKNOWN_COMMAND"


def test_stdout_is_json_only_for_list_models():
    """Real command touching huggingface_hub: every stdout line must be JSON
    (a stray print() here corrupts the Swift-side stream)."""
    lines = _run_backend('{"command": "list_models"}')
    assert lines, "list_models produced no output"
    for line in lines:
        msg = json.loads(line)  # raises if any line is not valid JSON
        assert "type" in msg
