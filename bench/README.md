# Piko Benchmarks

Research-driven benchmarks behind Piko's model choices. Everything runs
on-device (Apple Silicon) — the same hardware the product ships on.

| suite | status | what it measures |
|---|---|---|
| [asr/](asr/README.md) | ✅ done | Speech-to-text: WER/CER × speed across ru/en/de/fr (piko-audio-bench) + long-form real-recording engine comparison |
| [llm/](llm/README.md) | 🚧 planned | Local SLMs for Meeting Summary: quality × tokens/s (Qwen3.5 tiers etc.) |

Convention for every suite: a `README.md` with a jointly ranked
(quality × speed Pareto) leaderboard at the top, the exact data it was measured
on, and copy-paste reproduce commands. Raw artifacts (audio, model outputs,
vendor builds) stay gitignored; only code and reports are committed.
