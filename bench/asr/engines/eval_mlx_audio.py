# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-audio"]
# ///
"""Batch eval runner for mlx-audio STT models: load once, transcribe every wav
in an eval dir, write hyps JSONL.

Usage: uv run --script eval_mlx_audio.py <eval_dir> <model_repo> <out_jsonl> [bf16]

`bf16` (Parakeet only): load via the vendored `Model.from_pretrained(dtype=bf16)`
instead of the public `load_model()`, which keeps checkpoint dtype (fp32 for
Parakeet — see REPORT.md's dtype findings). bf16 was measured faster and at
equal RAM to parakeet-mlx.
"""

import json
import sys
import time
from pathlib import Path


def main() -> None:
    eval_dir = Path(sys.argv[1])
    model_repo = sys.argv[2]
    out = sys.argv[3]
    bf16 = len(sys.argv) > 4 and sys.argv[4] == "bf16"

    if bf16:
        import mlx.core as mx
        from mlx_audio.stt.models.parakeet.parakeet import Model

        t0 = time.perf_counter()
        model = Model.from_pretrained(model_repo, dtype=mx.bfloat16)
        mx.eval(model.parameters())
        load_s = time.perf_counter() - t0
    else:
        from mlx_audio.stt.utils import load_model

        t0 = time.perf_counter()
        model = load_model(model_repo)
        load_s = time.perf_counter() - t0

    is_whisper = "whisper" in model_repo.lower()
    refs = [json.loads(ln) for ln in (eval_dir / "refs.jsonl").open()]
    with open(out, "w") as f:
        engine_name = "mlx-audio-bf16" if bf16 else "mlx-audio"
        f.write(
            json.dumps({"meta": True, "model": model_repo, "engine": engine_name, "load_s": load_s})
            + "\n"
        )
        for r in refs:
            kwargs = {"language": r["lang"]} if is_whisper and r.get("lang") else {}
            t1 = time.perf_counter()
            res = model.generate(str(eval_dir / f"{r['id']}.wav"), **kwargs)
            dt = time.perf_counter() - t1
            text = getattr(res, "text", None) or str(res)
            f.write(
                json.dumps(
                    {"id": r["id"], "hyp": text, "transcribe_s": round(dt, 4)},
                    ensure_ascii=False,
                )
                + "\n"
            )


if __name__ == "__main__":
    main()
