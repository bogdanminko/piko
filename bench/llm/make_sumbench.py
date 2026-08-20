# /// script
# requires-python = ">=3.11"
# dependencies = ["datasets>=3.2", "transformers>=4.40", "tokenizers"]
# ///
"""Assemble piko-sum-bench: 6 summarization inputs, deliberately small.

This is an *engine* bench (llama.cpp vs mlx-engine), not a model bench: the same
Qwen3.5-4B weights, the same system prompt and greedy decoding on both sides.
Content semantics therefore barely matter — only two things move the numbers:

  1. Context length. The single claimed divergence between the engines is that
     MLX falls behind llama.cpp + FlashAttention past ~30k tokens. So the bench
     sweeps length: 2k / 8k / 24k, from real QMSum meeting transcripts.
  2. Language. Not for speed (throughput follows token count, not language) but
     for quantization parity: GGUF Q4_K_M and MLX 4bit are different quantizers,
     and Russian is the language most likely to expose a gap.

The ru/de/fr items are Piko's *actual* input distribution — parakeet ASR output
reused from the ASR suite, so no punctuation cleanup, no speaker labels. That is
what the summarizer will really see, and it costs zero downloads.

Prerequisite for the ru/de/fr items (gitignored artifacts, one command):
    uv run --script bench/asr/eval.py run pikobench parakeet

Usage:  uv run --script bench/llm/make_sumbench.py
Output: bench/llm/data/sumbench.jsonl
"""

import json
import re
import sys
from pathlib import Path

from datasets import load_dataset
from transformers import AutoTokenizer

BENCH = Path(__file__).parent
OUT = BENCH / "data" / "sumbench.jsonl"
ASR_HYPS = BENCH.parent / "asr" / "results" / "eval" / "pikobench--parakeet.jsonl"
TOKENIZER = "Qwen/Qwen3.5-4B"

# 24k sits just under the reported ~30k crossover, 8k is a realistic 40-minute
# call, 2k a stand-up. Three points is enough to see a slope; more would only
# add runtime.
BUCKETS = [("2k", 2_000), ("8k", 8_000), ("24k", 24_000)]
ASR_LANGS = ["ru", "de", "fr"]


def qmsum_items(tok):
    """English: real QMSum transcripts, truncated down to each target length."""
    ds = load_dataset("pszemraj/qmsum-cleaned", split="test")
    scored = []
    for row in ds:
        text = row.get("input") or row.get("text") or ""
        if "\n" in text:  # qmsum-cleaned prefixes a query line; drop it
            text = text.split("\n", 1)[1]
        if text.strip():
            scored.append(text)
        if len(scored) >= 120:
            break

    lengths = [(len(tok(t, add_special_tokens=False)["input_ids"]), t) for t in scored]
    items = []
    for name, target in BUCKETS:
        n, text = min(lengths, key=lambda p: abs(p[0] - target))
        if n > target:  # truncate down; never pad up with unrelated content
            text = tok.decode(tok(text, add_special_tokens=False)["input_ids"][:target])
            n = target
        items.append(
            dict(id=f"en-{name}", lang="en", bucket=name, n_tokens=n, text=text,
                 source="qmsum-cleaned/test")
        )
    return items


def asr_items(tok):
    """RU/DE/FR: concatenated parakeet output from the ASR suite (real ASR text)."""
    if not ASR_HYPS.exists():
        sys.exit(
            f"missing {ASR_HYPS}\nRun first: uv run --script bench/asr/eval.py run pikobench parakeet"
        )

    by_lang: dict[str, list[str]] = {lang: [] for lang in ASR_LANGS}
    for line in ASR_HYPS.open():
        row = json.loads(line)
        if row.get("meta"):
            continue
        match = re.search(r"fleurs_(\w\w)", row.get("id", ""))
        if match and match.group(1) in by_lang:
            by_lang[match.group(1)].append(str(row.get("hyp", "")).strip())

    items = []
    for lang in ASR_LANGS:
        text = " ".join(by_lang[lang]).strip()
        if not text:
            sys.exit(f"no {lang} hypotheses found in {ASR_HYPS}")
        items.append(
            dict(id=f"{lang}-asr", lang=lang, bucket="asr", text=text,
                 n_tokens=len(tok(text, add_special_tokens=False)["input_ids"]),
                 source="bench/asr parakeet hypotheses (fleurs)")
        )
    return items


def main() -> None:
    tok = AutoTokenizer.from_pretrained(TOKENIZER)
    OUT.parent.mkdir(parents=True, exist_ok=True)

    rows = qmsum_items(tok) + asr_items(tok)
    for row in rows:
        print(f"{row['id']:10s} {row['n_tokens']:6d} tokens  {row['source']}")

    with OUT.open("w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"\n{len(rows)} items -> {OUT}")


if __name__ == "__main__":
    main()
