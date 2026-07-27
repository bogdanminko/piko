# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4"]
# ///
"""Measure what Qwen3.5's native MTP head is actually worth on Apple Silicon.

The question is not "is decode faster" but "does the wall clock a user waits
move". Piko feeds a 30-minute meeting transcript (~21k tokens) into the SLM, so
prefill dominates and a decode-only speedup is diluted; the short items are the
other end of that range. Every row therefore reports the prefill/decode split,
not just tokens/s.

What varies is only the decode loop: --mtp on/off inside one runtime, loading the
same directory both ways (the head is resident either way). What that costs in
quality is checked by hashing the greedy output: MTP is supposed to be
distribution-preserving, so any divergence is a finding in itself.

Each cell is a fresh process under /usr/bin/time -l, one discarded warmup per
(model, flag) so Metal kernel compilation never lands in a measured run, then
--reps measured runs whose median is reported.

Usage: uv run --script bench/llm/mtp_eval.py [--models 9B,4B,9B-bf16head] [--reps 2]
Output: bench/llm/results/MTP_RESULTS.jsonl + a table on stdout
"""

import argparse
import hashlib
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

BENCH = Path(__file__).parent
ROOT = BENCH.parent.parent
DATA = BENCH / "data" / "sumbench.jsonl"
TASK = BENCH / "task.json"
RESULTS = BENCH / "results" / "MTP_RESULTS.jsonl"
PYTHON = BENCH / "vendor" / "mlx-lm-mtp" / ".venv" / "bin" / "python"
RUNNER = BENCH / "engines" / "run_mlx_mtp.py"
MODELS_DIR = BENCH / "vendor" / "models"

MODELS = {
    "9B": "Qwen3.5-9B-4bit-mtp",
    "4B": "Qwen3.5-4B-4bit-mtp",
    "9B-bf16head": "Qwen3.5-9B-4bit-mtp-bf16head",
}

# ru-asr and en-2k are decode-heavy; en-24k is the one that looks like a real
# 30-minute meeting, which is where a decode-only win gets diluted.
ITEMS = ["ru-asr", "en-2k", "en-24k"]
WARMUP_ITEM = "ru-asr"

MAX_RSS = re.compile(r"(\d+)\s+maximum resident set size")


def run_one(model_dir: Path, item: dict, mtp: bool) -> dict:
    cmd = ["/usr/bin/time", "-l", str(PYTHON), str(RUNNER),
           "--model", str(model_dir), "--task", str(TASK),
           "--item", json.dumps(item, ensure_ascii=False)]
    if mtp:
        cmd.append("--mtp")
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(ROOT))
    total = time.perf_counter() - t0
    try:
        m = json.loads(proc.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {"error": "no metrics", "stderr": proc.stderr[-1200:], "total_s": total}
    rss = MAX_RSS.search(proc.stderr)
    m["peak_rss_mb"] = int(rss.group(1)) / (1024 * 1024) if rss else None
    m["total_s"] = total
    return m


def median_of(runs: list[dict], key: str):
    vals = [r[key] for r in runs if r.get(key) is not None]
    return statistics.median(vals) if vals else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="9B,4B")
    ap.add_argument("--items", default=",".join(ITEMS))
    ap.add_argument("--reps", type=int, default=2)
    args = ap.parse_args()

    if not PYTHON.exists():
        sys.exit(f"missing {PYTHON}\nClone mlx-lm at PR #990 into "
                 f"{PYTHON.parent.parent} and create its venv (see README)")
    items = {json.loads(line)["id"]: json.loads(line) for line in DATA.open()}
    task = json.loads(TASK.read_text())
    wanted = [m.strip() for m in args.models.split(",")]
    item_ids = [i.strip() for i in args.items.split(",")]

    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with RESULTS.open("w") as out:
        for name in wanted:
            model_dir = MODELS_DIR / MODELS[name]
            if not (model_dir / "model-mtp.safetensors").exists():
                print(f"skipping {name}: no MTP head at {model_dir}\n"
                      f"  build it: uv run --script bench/llm/make_mtp_head.py "
                      f"--size {name.split('-')[0]}", flush=True)
                continue
            for mtp in (False, True):
                label = f"{name} mtp={'on ' if mtp else 'off'}"
                print(f"warmup   {label} ...", flush=True)
                run_one(model_dir, items[WARMUP_ITEM], mtp)
                for item_id in item_ids:
                    print(f"running  {label} {item_id} x{args.reps} ...", flush=True)
                    runs = [run_one(model_dir, items[item_id], mtp)
                            for _ in range(args.reps)]
                    bad = [r for r in runs if "error" in r]
                    if bad:
                        print(f"  FAILED: {bad[0]['error']}\n"
                              f"{bad[0].get('stderr','')[:600]}", flush=True)
                        continue
                    texts = {hashlib.sha1(r["text"].encode()).hexdigest()[:10]
                             for r in runs}
                    row = {
                        "model": name, "mtp": mtp, "item": item_id,
                        "lang": items[item_id]["lang"],
                        "prompt_tokens": runs[0].get("prompt_tokens"),
                        "reps": args.reps,
                        "deterministic": len(texts) == 1,
                        "text_sha": sorted(texts)[0],
                        "prefill_tps": median_of(runs, "prefill_tps"),
                        "decode_tps": median_of(runs, "decode_tps"),
                        "ttft_s": median_of(runs, "ttft_s"),
                        "wall_s": median_of(runs, "wall_s"),
                        "gen_tokens": median_of(runs, "gen_tokens"),
                        "acceptance": median_of(runs, "acceptance"),
                        "peak_rss_mb": median_of(runs, "peak_rss_mb"),
                        "schema_ok": all(check_schema(r["text"], task["schema"])
                                         for r in runs),
                        "text": runs[0]["text"],
                    }
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    rows.append(row)
                    print(f"  prefill {row['prefill_tps'] or 0:7.1f} tok/s | "
                          f"decode {row['decode_tps'] or 0:6.1f} tok/s | "
                          f"ttft {row['ttft_s'] or 0:5.1f}s | "
                          f"wall {row['wall_s']:6.2f}s | "
                          f"acc {('%.0f%%' % (100 * row['acceptance'])) if row['acceptance'] else '  - ':>5s} | "
                          f"json={row['schema_ok']} sha={row['text_sha']}",
                          flush=True)

    report(rows)
    print(f"\n-> {RESULTS}")


def check_schema(text: str, schema: dict) -> bool:
    """Unconstrained decoding: the JSON may arrive fenced or wrapped in prose."""
    import jsonschema

    body = text.strip()
    if "```" in body:
        body = max(body.split("```"), key=len).removeprefix("json").strip()
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return False
    try:
        jsonschema.validate(json.loads(body[start : end + 1]), schema)
    except Exception:
        return False
    return True


def report(rows: list[dict]) -> None:
    """Pair each mtp=on row with its mtp=off twin and show what actually moved."""
    print(f"\n{'model':12s} {'item':8s} {'prompt':>7s} {'decode off':>11s} "
          f"{'decode on':>10s} {'decode x':>9s} {'wall off':>9s} {'wall on':>8s} "
          f"{'wall x':>7s} {'acc':>5s} {'same out':>9s}")
    by_key = {(r["model"], r["item"], r["mtp"]): r for r in rows}
    for (model, item, mtp), on in sorted(by_key.items()):
        if not mtp:
            continue
        off = by_key.get((model, item, False))
        if not off:
            continue
        d_off, d_on = off["decode_tps"] or 0, on["decode_tps"] or 0
        w_off, w_on = off["wall_s"], on["wall_s"]
        print(f"{model:12s} {item:8s} {off['prompt_tokens'] or 0:7d} "
              f"{d_off:11.1f} {d_on:10.1f} {d_on / d_off if d_off else 0:8.2f}x "
              f"{w_off:9.2f} {w_on:8.2f} {w_off / w_on if w_on else 0:6.2f}x "
              f"{100 * (on['acceptance'] or 0):4.0f}% "
              f"{str(off['text_sha'] == on['text_sha']):>9s}")


if __name__ == "__main__":
    main()
