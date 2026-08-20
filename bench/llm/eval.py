# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4", "huggingface-hub>=0.30"]
# ///
"""Run the piko-sum-bench matrix across both engines and score it.

14 runs, ~15 minutes. Same weights (Qwen3.5-4B at 4-bit), same system prompt and
schema (task.json), temp=0, seed=0, reasoning off on both sides. What varies is
only the engine, the context length, and whether the schema is enforced:

  speed vs context   en-2k / en-8k / en-24k   both engines, schema on   (6)
  cost of schema     en-24k                   both engines, schema off  (2)
  quant parity       ru/de/fr-asr             both engines, schema on   (6)

Each run is a fresh process wrapped in /usr/bin/time -l, so load time and peak
RSS are measured the same way for both engines and nothing is cached between
items.

Usage: uv run --script bench/llm/eval.py [--only llamacpp|mlx-engine]
Output: bench/llm/results/RESULTS.jsonl + a table on stdout
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import jsonschema

BENCH = Path(__file__).parent
ROOT = BENCH.parent.parent
DATA = BENCH / "data" / "sumbench.jsonl"
TASK = BENCH / "task.json"
RESULTS = BENCH / "results" / "RESULTS.jsonl"

GGUF = BENCH / "vendor" / "gguf" / "Qwen3.5-4B-Q4_K_M.gguf"
MLX_REPO = "mlx-community/Qwen3.5-4B-4bit"
MLX_PYTHON = BENCH / "vendor" / "mlx-engine" / ".venv" / "bin" / "python"

# (item_id, schema_on) — every pair runs on both engines.
MATRIX = [
    ("en-2k", True),
    ("en-8k", True),
    ("en-24k", True),
    ("en-24k", False),  # schema-enforcement cost, measured where it costs most
    ("ru-asr", True),
    ("de-asr", True),
    ("fr-asr", True),
]

MAX_RSS = re.compile(r"(\d+)\s+maximum resident set size")


def run_one(engine: str, item: dict, schema_on: bool, mlx_path: str) -> dict:
    """One engine x item run, wrapped in /usr/bin/time -l for peak RSS."""
    item_json = json.dumps(item, ensure_ascii=False)
    if engine == "llamacpp":
        cmd = [sys.executable, str(BENCH / "engines" / "run_llamacpp.py"),
               "--model", str(GGUF)]
    else:
        cmd = [str(MLX_PYTHON), str(BENCH / "engines" / "run_mlx_engine.py"),
               "--model", mlx_path]
    cmd += ["--item", item_json, "--task", str(TASK)]
    if not schema_on:
        cmd.append("--no-schema")

    t0 = time.perf_counter()
    proc = subprocess.run(["/usr/bin/time", "-l", *cmd], capture_output=True, text=True,
                          cwd=str(ROOT))
    total = time.perf_counter() - t0

    try:
        metrics = json.loads(proc.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {"error": "no metrics", "stderr": proc.stderr[-800:], "total_s": total}

    rss = MAX_RSS.search(proc.stderr)
    metrics["peak_rss_mb"] = int(rss.group(1)) / (1024 * 1024) if rss else None
    metrics["total_s"] = total
    return metrics


def check_schema(text: str, schema: dict) -> bool:
    """Did the model emit something that actually validates against the schema?"""
    body = text.strip()
    # Unconstrained runs may wrap JSON in prose or a fenced block.
    if "```" in body:
        parts = body.split("```")
        body = max(parts, key=len).removeprefix("json").strip()
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return False
    try:
        jsonschema.validate(json.loads(body[start : end + 1]), schema)
    except Exception:
        return False
    return True


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["llamacpp", "mlx-engine"])
    args = ap.parse_args()

    if not DATA.exists():
        sys.exit(f"missing {DATA}\nRun first: uv run --script bench/llm/make_sumbench.py")
    if not GGUF.exists():
        sys.exit(f"missing {GGUF}")

    from huggingface_hub import snapshot_download

    mlx_path = snapshot_download(MLX_REPO)

    items = {json.loads(line)["id"]: json.loads(line) for line in DATA.open()}
    task = json.loads(TASK.read_text())
    engines = [args.only] if args.only else ["llamacpp", "mlx-engine"]

    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with RESULTS.open("w") as out:
        for item_id, schema_on in MATRIX:
            for engine in engines:
                label = f"{item_id:8s} {engine:11s} schema={'on ' if schema_on else 'off'}"
                print(f"running  {label} ...", flush=True)
                m = run_one(engine, items[item_id], schema_on, mlx_path)
                row = {
                    "item": item_id, "engine": engine, "schema": schema_on,
                    "lang": items[item_id]["lang"], "n_tokens": items[item_id]["n_tokens"],
                    **m,
                }
                row["schema_ok"] = check_schema(m.get("text", ""), task["schema"])
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
                rows.append(row)
                if "error" in m:
                    print(f"  FAILED: {m['error']}\n{m.get('stderr', '')[:400]}", flush=True)
                else:
                    print(
                        f"  prefill {m['prefill_tps'] or 0:7.1f} tok/s | "
                        f"decode {m['decode_tps'] or 0:6.1f} tok/s | "
                        f"{m['wall_s']:5.1f}s | {m.get('peak_rss_mb') or 0:6.0f} MB | "
                        f"schema_ok={row['schema_ok']}",
                        flush=True,
                    )

    print(f"\n{'item':9s} {'engine':11s} {'sch':4s} {'prefill':>9s} {'decode':>8s} "
          f"{'wall':>7s} {'RSS MB':>8s} {'valid':>6s}")
    for r in rows:
        print(f"{r['item']:9s} {r['engine']:11s} {'on' if r['schema'] else 'off':4s} "
              f"{r.get('prefill_tps') or 0:9.1f} {r.get('decode_tps') or 0:8.1f} "
              f"{r.get('wall_s') or 0:7.1f} {r.get('peak_rss_mb') or 0:8.0f} "
              f"{str(r.get('schema_ok')):>6s}")
    print(f"\n-> {RESULTS}")


if __name__ == "__main__":
    main()
