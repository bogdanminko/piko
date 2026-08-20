# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""llama.cpp runner: one sumbench item -> one JSON metrics line on stdout.

Uses llama-server rather than llama-cli for two reasons: its OpenAI-compatible
endpoint takes `response_format: json_schema` natively (llama.cpp compiles the
schema to GBNF internally), and it reports exact `timings` — prompt_per_second
and predicted_per_second — instead of the CLI's scraped stdout banner.

A fresh server is started and torn down per item, so load time and peak RSS stay
comparable to the mlx-engine runner, which is also a fresh process per item.
`cache_prompt: false` keeps llama.cpp's prefix cache from flattering the second
run over an identical prompt (the schema-on / schema-off pair on en-24k).

Usage: run_llamacpp.py --model X.gguf --item <json> --task task.json [--no-schema]
"""

import argparse
import json
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BIN = Path(__file__).parent.parent / "vendor" / "llama.cpp" / "build" / "bin" / "llama-server"
STARTUP_TIMEOUT_S = 180


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_healthy(port: int, proc: subprocess.Popen) -> float:
    """Block until the server answers /health; return seconds spent loading."""
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < STARTUP_TIMEOUT_S:
        if proc.poll() is not None:
            sys.exit(f"llama-server died during startup (rc={proc.returncode})")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                if json.loads(r.read()).get("status") == "ok":
                    return time.perf_counter() - t0
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ConnectionError):
            time.sleep(0.5)
    sys.exit("llama-server did not become healthy in time")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--item", required=True, help="sumbench item as a JSON string")
    ap.add_argument("--task", required=True)
    ap.add_argument("--no-schema", action="store_true")
    args = ap.parse_args()

    item = json.loads(args.item)
    task = json.loads(Path(args.task).read_text())
    port = free_port()

    proc = subprocess.Popen(
        [
            str(BIN), "-m", args.model,
            "--port", str(port),
            "-c", str(item["n_tokens"] + task["max_tokens"] + 1024),
            "-fa", "on",     # FlashAttention: llama.cpp's claimed long-context edge
            "--jinja",       # needed for chat_template_kwargs to reach the template
            "--no-warmup",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )

    try:
        load_s = wait_healthy(port, proc)

        payload = {
            "messages": [
                {"role": "system", "content": task["system"]},
                {"role": "user",
                 "content": task["user_template"].format(transcript=item["text"])},
            ],
            "temperature": task["temperature"],
            "seed": task["seed"],
            "max_tokens": task["max_tokens"],
            "cache_prompt": False,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        if not args.no_schema:
            payload["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "summary", "schema": task["schema"]},
            }

        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=1800) as r:
            body = json.loads(r.read())
        wall = time.perf_counter() - t0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()

    t = body.get("timings", {})
    print(json.dumps({
        "prefill_tps": t.get("prompt_per_second"),
        "decode_tps": t.get("predicted_per_second"),
        "gen_tokens": t.get("predicted_n"),
        "prompt_tokens": t.get("prompt_n"),
        "load_s": load_s,
        "wall_s": wall,
        "text": body["choices"][0]["message"]["content"],
        "returncode": 0,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
