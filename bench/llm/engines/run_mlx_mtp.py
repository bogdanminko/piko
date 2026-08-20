"""mlx-lm runner with native MTP speculative decoding: one item -> one JSON line.

Runs under bench/llm/vendor/mlx-lm-mtp/.venv, a clone of mlx-lm checked out at
PR #990 (native MTP for Qwen3.5/3.6). Nothing here touches Piko's own venv, and
the MTP path is deliberately mlx-lm's rather than a third-party runtime.

The model directory must carry an MTP head — build one with make_mtp_head.py.
Both --mtp and --no-mtp load the *same* directory, so the head sits in memory
either way and the only thing that varies is the decode loop.

Prefill/decode are split by timing the first yielded token, the same way
run_mlx_engine.py and llama.cpp do it, so numbers stay comparable across all
three runners. mlx-lm's own prompt_tps/generation_tps are recorded too, as a
cross-check on that split.

Acceptance comes from `from_draft` on each response: with depth 1 every backbone
step proposes exactly one draft token, so accepted/(total-accepted) is the
acceptance rate.

Usage: run_mlx_mtp.py --model <dir> --item <json> --task task.json [--mtp]
"""

import argparse
import json
import time

from mlx_lm import load
from mlx_lm.generate import stream_generate


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="local model dir with an MTP head")
    ap.add_argument("--item", required=True, help="sumbench item as a JSON string")
    ap.add_argument("--task", required=True)
    ap.add_argument("--mtp", action="store_true")
    args = ap.parse_args()

    item = json.loads(args.item)
    with open(args.task) as f:
        task = json.load(f)

    t0 = time.perf_counter()
    model, tokenizer = load(args.model)
    load_s = time.perf_counter() - t0

    prompt = tokenizer.apply_chat_template(
        [
            {"role": "system", "content": task["system"]},
            {"role": "user", "content": task["user_template"].format(transcript=item["text"])},
        ],
        add_generation_prompt=True,
        enable_thinking=False,
    )

    t1 = time.perf_counter()
    ttft = None
    chunks, gen_tokens, accepted = [], 0, 0
    last = None
    for resp in stream_generate(
        model,
        tokenizer,
        prompt,
        max_tokens=task["max_tokens"],
        temp=task["temperature"],
        mtp=args.mtp,
    ):
        if ttft is None:
            ttft = time.perf_counter() - t1
        chunks.append(resp.text)
        gen_tokens += 1
        accepted += bool(resp.from_draft)
        last = resp
    wall = time.perf_counter() - t1

    decode_s = wall - (ttft or 0)
    backbone_steps = gen_tokens - accepted
    print(
        json.dumps(
            {
                "prefill_tps": len(prompt) / ttft if ttft else None,
                "decode_tps": (gen_tokens - 1) / decode_s if decode_s > 0 and gen_tokens > 1 else None,
                "gen_tokens": gen_tokens,
                "prompt_tokens": len(prompt),
                "accepted_draft": accepted,
                "acceptance": accepted / backbone_steps if backbone_steps else None,
                "load_s": load_s,
                "wall_s": wall,
                "ttft_s": ttft,
                # mlx-lm's own accounting, as a check on the ttft-based split.
                "mlx_prompt_tps": getattr(last, "prompt_tps", None),
                "mlx_generation_tps": getattr(last, "generation_tps", None),
                "peak_memory_gb": getattr(last, "peak_memory", None),
                "finish_reason": getattr(last, "finish_reason", None),
                "text": "".join(chunks).strip(),
                "returncode": 0,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
