# /// script
# requires-python = ">=3.11"
# dependencies = ["parakeet-mlx"]
# ///
"""Batch eval runner for parakeet-mlx: load model once, transcribe every wav in
an eval dir, write hyps JSONL.

Usage: uv run --script eval_parakeet.py <eval_dir> <model_repo> <out_jsonl>
"""

import json
import sys
import time
from pathlib import Path


def main() -> None:
    eval_dir = Path(sys.argv[1])
    model_repo = sys.argv[2]
    out = sys.argv[3]

    from parakeet_mlx import from_pretrained

    t0 = time.perf_counter()
    model = from_pretrained(model_repo)
    load_s = time.perf_counter() - t0

    refs = [json.loads(ln) for ln in (eval_dir / "refs.jsonl").open()]
    with open(out, "w") as f:
        f.write(json.dumps({"meta": True, "model": model_repo, "load_s": load_s}) + "\n")
        for r in refs:
            t1 = time.perf_counter()
            res = model.transcribe(str(eval_dir / f"{r['id']}.wav"))
            dt = time.perf_counter() - t1
            f.write(
                json.dumps(
                    {"id": r["id"], "hyp": res.text, "transcribe_s": round(dt, 4)},
                    ensure_ascii=False,
                )
                + "\n"
            )


if __name__ == "__main__":
    main()
