# Piko LLM Benchmark (planned)

Local SLM evaluation for the Meeting Summary skill: summarization quality ×
generation speed (tokens/s) × memory, on Apple Silicon via mlx-lm.

Planned matrix: Qwen3.5 2B / 4B / 9B (fast / balanced / quality tiers — see
`docs/PRODUCT.md`). Methodology TBD; will follow the same convention as
[asr/](../asr/README.md): Pareto-ranked leaderboard, exact eval data disclosed,
reproduce commands.
