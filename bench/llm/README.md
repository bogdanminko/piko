# Piko LLM Benchmark

Local SLM evaluation for the Meeting Summary skill: summarization quality ×
generation speed (tokens/s) × memory, on Apple Silicon.

Planned matrix: Qwen3.5 2B / 4B / 9B (fast / balanced / quality tiers — see
`docs/PRODUCT.md`), following the same convention as [asr/](../asr/README.md):
Pareto-ranked leaderboard, exact eval data disclosed, reproduce commands.

Eval data is `data/sumbench.jsonl` (`make_sumbench.py`), the task — one system
prompt plus a JSON schema — is `task.json`.

**These items are not the shape the app runs.** `summarize_meeting` is
map-reduce (`skills/meeting/summary.py`): `CHUNK_CHARS = 6000` with 600 of
overlap, so a 30-minute meeting becomes ~16 prompts of ~1.5k tokens, mapped in
2 batched waves of 8 (`BATCH_SIZE` in `core/llm/mlx_backend.py`) and then
reduced. So `en-2k` is the product-shaped row and `en-24k` is a stress row for
the single-prompt path — useful for isolating prefill behaviour, misleading if
read as "one meeting".

## Engines

| runner | runtime | schema enforcement |
|---|---|---|
| `engines/run_llamacpp.py` | vendored llama.cpp + GGUF | GBNF grammar |
| `engines/run_mlx_engine.py` | vendored mlx-engine (LM Studio's) | Outlines (`json_schema=`) |
| `engines/run_mlx_mtp.py` | vendored mlx-lm at [PR #990](https://github.com/ml-explore/mlx-lm/pull/990) | **none** |

All three report the same metrics and split prefill from decode by timing the
first yielded token, so numbers are comparable across runners. Everything lives
under `vendor/` (gitignored) with its own venv — none of it is a Piko
dependency, and no third-party inference runtime is used.

## Result: native MTP speculative decoding is not worth adopting

`uv run --script bench/llm/mtp_eval.py --models 9B,4B,9B-bf16head`
→ `results/MTP_RESULTS.jsonl`

Qwen3.5 checkpoints ship a Multi-Token Prediction head that drafts token *t+2*,
so decode can emit up to two tokens per backbone pass. mlx-lm 0.31.3 discards
those weights during conversion (one line in `qwen3_5.py`'s `sanitize()`), which
is why every `mlx-community/Qwen3.5-*` repo declares `mtp_num_hidden_layers: 1`
and contains no `mtp.*` tensors. `make_mtp_head.py` grafts the head back on by
fetching just its 15 tensors out of the upstream bf16 checkpoint by byte range —
487 MB for 9B rather than a 19 GB download.

It works: acceptance is 66–88%, matching published figures. It still loses.

**Decode is 19–21% of the wall clock on a real transcript, and MTP taxes the
other 80%** — it runs the head across the whole prompt to fill its own cache.
On `en-24k`:

| model | prefill tax | decode saving | net |
|---|---|---|---|
| 4B | +1.6 s | +0.4 s | **−1.2 s** |
| 9B (bf16 head) | +3.9 s | +0.9 s | **−3.1 s** |
| 9B (4-bit head) | +14.3 s | −1.0 s | **−15.4 s** |

MTP only wins where the prompt is short: 4B on `ru-asr` goes 6.38 s → 5.48 s
(1.16×) — which *is* close to the app's per-chunk shape.

That is not a reason to reconsider, because of a second, independent
disqualifier: **MTP runs on solo requests only** — mlx-lm falls back to standard
generation for concurrent ones. The phase where decode's share is highest is the
map phase, and the map phase is already batched, which harvests the same
throughput by a mechanism MTP cannot coexist with. What is left for MTP is the
single reduce pass, and one pass is not worth an unmerged 700-line patch plus a
weight-grafting step in the model registry.

Secondary findings:

* **Quantizing the MTP head is free.** 4-bit vs bf16 head, same base: acceptance
  66/66, 87/88, 76/75, and byte-identical output. The bf16 head's extra 350 MB
  buys nothing. Its input embedding and output projection are the base's 4-bit
  tensors either way (`tie_word_embeddings: false`,
  `mtp_use_dedicated_embeddings: false`), which caps what full precision could
  do in the first place.
* **MTP is not output-preserving here.** Greedy output differs from plain
  greedy decoding, though each path is deterministic and both head precisions
  agree with each other — so the drift is in the backbone's verify pass (S=2
  hits different kernels than S=1), not in the head. The accept logic itself is
  exact (`verify_pred == draft_tok` for greedy; rejection sampling with residual
  resampling above it). Worth knowing before believing "1.4× at no cost".
* **Unconstrained decoding does not follow the schema: 0 of 18 runs validated.**
  4B invents its own keys (`meeting_summary`, `participants`, `key_topics`) and
  runs into the 512-token cap mid-object. Schema enforcement is load-bearing,
  and the mlx-lm path has none — which is a stronger argument against it than
  MTP's speed ever was.

### Methodology caveat: this harness's noise floor is ±19%

Each cell is a fresh process under `/usr/bin/time -l`, with one discarded warmup
per (model, flag) — the first run pays Metal kernel compilation and, left in,
inverts the sign of the result. That is not enough.

`9B` and `9B-bf16head` share one base checkpoint, and with `--mtp` off the head
is never called: identical code, identical weights. They measured 68.8 vs
55.9 tok/s. The 19% gap is pure machine drift over a 20-minute run (thermals,
block order), and it is larger than the effect being measured. **Blocked A/B is
therefore invalid at this resolution; on/off must be interleaved within a cell.**
The conclusion above survives because its sign is the same in all three blocks
including adjacent ones, but the −15.4 s magnitude does not — it is mostly drift.
