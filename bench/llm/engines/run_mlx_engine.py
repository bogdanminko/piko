"""mlx-engine runner: one sumbench item -> one JSON metrics line on stdout.

Runs under bench/llm/vendor/mlx-engine/.venv (python3.11, mlx-engine pins its
requirements exactly and cannot share Piko's 3.13 venv). Schema enforcement goes
through mlx-engine's native Outlines path (`json_schema=`), the same code LM
Studio ships.

Prefill/decode are separated by timing the first yielded token: everything up to
it is prompt processing, everything after is generation — the same split
llama.cpp reports as "prompt eval" vs "eval".

Usage: run_mlx_engine.py --model <hf-path> --item <json> --task task.json [--no-schema]
"""

import argparse
import json
import sys
import time
from pathlib import Path

# mlx-engine is a vendored clone, not an installed package.
sys.path.insert(0, str(Path(__file__).parent.parent / "vendor" / "mlx-engine"))

from mlx_engine.generate import create_generator, load_model, tokenize  # noqa: E402
from transformers import AutoTokenizer  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--item", required=True, help="sumbench item as a JSON string")
    ap.add_argument("--task", required=True)
    ap.add_argument("--no-schema", action="store_true")
    args = ap.parse_args()

    item = json.loads(args.item)
    with open(args.task) as f:
        task = json.load(f)

    t0 = time.perf_counter()
    # max_kv_size=None: the 4096 default would silently truncate the 24k item.
    model_kit = load_model(args.model, max_kv_size=None, seed=task["seed"])
    load_s = time.perf_counter() - t0

    tf_tokenizer = AutoTokenizer.from_pretrained(args.model)
    prompt = tf_tokenizer.apply_chat_template(
        [
            {"role": "system", "content": task["system"]},
            {"role": "user", "content": task["user_template"].format(transcript=item["text"])},
        ],
        tokenize=False,
        add_generation_prompt=True,
        enable_thinking=False,  # no thinking tokens, matching llama.cpp's -rea off
    )
    prompt_tokens = tokenize(model_kit, prompt)

    kwargs = dict(max_tokens=task["max_tokens"], temp=task["temperature"], seed=task["seed"])
    if not args.no_schema:
        kwargs["json_schema"] = json.dumps(task["schema"])

    t1 = time.perf_counter()
    ttft = None
    chunks, gen_tokens = [], 0
    for result in create_generator(model_kit, prompt_tokens, **kwargs):
        if ttft is None:
            ttft = time.perf_counter() - t1
        chunks.append(result.text)
        gen_tokens += len(result.tokens)
    wall = time.perf_counter() - t1

    decode_s = wall - (ttft or 0)
    print(
        json.dumps(
            {
                "prefill_tps": len(prompt_tokens) / ttft if ttft else None,
                "decode_tps": (gen_tokens - 1) / decode_s if decode_s > 0 and gen_tokens > 1 else None,
                "gen_tokens": gen_tokens,
                "load_s": load_s,
                "wall_s": wall,
                "text": "".join(chunks).strip(),
                "returncode": 0,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
