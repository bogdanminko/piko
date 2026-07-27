# Piko Benchmarks

Research-driven benchmarks behind Piko's model choices. Everything runs
on-device (Apple Silicon) — the same hardware the product ships on.

| suite | status | what it measures |
|---|---|---|
| [asr/](asr/README.md) | ✅ done | Speech-to-text: WER/CER × speed across ru/en/de/fr (piko-audio-bench) + long-form real-recording engine comparison |
| [llm/](llm/README.md) | 🚧 planned | Local SLMs for Meeting Summary: quality × tokens/s (Qwen3.5 tiers etc.) |
| [speakers/](speakers/README.md) | 🚧 open question | Who spoke: whether the ASR encoder's own states can replace the diarization model, probed per layer against two-track ground truth |

## The research environment

`bench/` is its own uv project ([`pyproject.toml`](pyproject.toml)) with its own
lockfile and `.venv`, pinned to the same Python as the app (3.13). It depends on
`piko` as an editable path, so notebooks and scripts measure the real shipping
code rather than a copy.

It is separate on purpose: the Swift side bootstraps the product's venv with
`uv sync --frozen`, so anything added to the root project is downloaded by every
user on first launch. Jupyter and matplotlib have no business in there.

```bash
uv sync --project bench
uv run --project bench jupyter lab
```

Convention for every suite: a `README.md` with a jointly ranked
(quality × speed Pareto) leaderboard at the top, the exact data it was measured
on, and copy-paste reproduce commands. Raw artifacts (audio, model outputs,
vendor builds) stay gitignored; only code and reports are committed.
