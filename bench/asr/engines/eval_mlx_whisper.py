"""Batch eval runner for mlx-whisper: load model once, transcribe every wav in
an eval dir, write hyps JSONL. Runs in the project venv.

Usage: python eval_mlx_whisper.py <eval_dir> <model_repo> <out_jsonl> [--lang xx]
"""

import argparse
import json
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("eval_dir")
    parser.add_argument("model")
    parser.add_argument("out")
    parser.add_argument("--lang", default=None)
    args = parser.parse_args()

    import mlx.core as mx
    import mlx_whisper
    from mlx_whisper.transcribe import ModelHolder

    t0 = time.perf_counter()
    ModelHolder.get_model(args.model, mx.float16)
    load_s = time.perf_counter() - t0

    eval_dir = Path(args.eval_dir)
    refs = [json.loads(ln) for ln in (eval_dir / "refs.jsonl").open()]
    with open(args.out, "w") as f:
        f.write(json.dumps({"meta": True, "model": args.model, "load_s": load_s}) + "\n")
        for r in refs:
            t1 = time.perf_counter()
            res = mlx_whisper.transcribe(
                str(eval_dir / f"{r['id']}.wav"),
                path_or_hf_repo=args.model,
                language=r.get("lang") or args.lang,
                verbose=None,
            )
            dt = time.perf_counter() - t1
            f.write(
                json.dumps(
                    {"id": r["id"], "hyp": res["text"], "transcribe_s": round(dt, 4)},
                    ensure_ascii=False,
                )
                + "\n"
            )


if __name__ == "__main__":
    main()
