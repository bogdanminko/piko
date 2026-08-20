# ASR Engine Benchmark — Results (long-form / v1)

Date: 2026-07-26 · Hardware: Apple M4 Max, 14-core CPU, 32-core GPU, 36 GB RAM
Input: first 30 min of a real Russian tech screencast, 16 kHz mono WAV.
Protocol: fresh process per run, 1 cold + 2 warm, median warm reported.
This is the engine-runtime benchmark (see the [main leaderboard](README.md)
for the model/WER comparison on FLEURS — the two are complementary: this one
catches failure modes read speech can't). Raw per-run JSON was not retained;
the numbers below are the full record of that run.

## Methodology

Goal: pick the transcription engine for Piko's Meeting Summary vertical (and
sanity-check the captions path) — speed, quality, and memory on Apple Silicon,
using the *same* Whisper weights across engines, plus Parakeet as the speed
contender.

**Test material**: first 30 min of a real Russian tech screen-recording demo,
not redistributed (personal recording, gitignored) — matches the actual
product use case (meetings) in a way FLEURS' read speech cannot. Extracted
once to a 16 kHz mono WAV so every engine gets byte-identical input; a 20 s
probe clip was used for smoke tests before full runs. Neither file is kept on
disk after the bench ran — regenerate from any ~30 min recording to rerun.

**Engines tested**, all on `mlx-community/whisper-large-v3-turbo` (or its ggml
equivalent) except where noted: mlx-whisper (current backend, with and without
`word_timestamps=True`, since that's what the captions path pays), whisper.cpp
`whisper-cli` (Metal), transcribe-rs (Rust wrapper over whisper.cpp — the
[meetily](https://github.com/Zackriya-Solutions/meetily) stack), parakeet-mlx,
and mlx-audio's STT module (parakeet v3 with the same weights, to isolate
mlx-audio's framework overhead from parakeet-mlx's). Metrics per run (fresh
process each time, 1 cold + 2 warm, cold `load_s` + median warm `transcribe_s`
reported): load time, transcription time (→ RTF), wall clock, peak RSS
(`/usr/bin/time -l`).

**Quality was a pass/fail gate here, not the headline** — the point of v1 was
on-device speed; quality only needed to clear "usable for meeting
summarization" (coarse WER vs. the mlx-whisper baseline transcript, no ground
truth). RTF was also used as a realtime-latency proxy (≥5× means a 10 s chunk
processes in ≤2 s, fine for live captioning). Full detail: `run.py` +
`wer.py` are the orchestrator and scorer; engine runners live in `engines/`.
`bench/` is not part of the shipped app and is not wired into CI.

## Speed (the headline)

| engine | weights | load (cold) | transcribe 30 min | RTF | peak RSS |
|---|---|---|---|---|---|
| **mlx-audio (bf16)** | parakeet-tdt-0.6b-v3 | 0.71 s | **8.4 s** | **215x** | 1182 MB |
| **mlx-audio (fp32, its API default)** | parakeet-tdt-0.6b-v3 | 0.90 s | **10.8 s** | **167x** | 2794 MB |
| **mlx-audio (fp16)** | parakeet-tdt-0.6b-v3 | 1.64 s | **12.3 s** | **147x** | 1186 MB |
| **parakeet-mlx** | parakeet-tdt-0.6b-v3 | 1.16 s | **16.1 s** | **112x** | **965 MB** |
| mlx-audio whisper (fp16) | large-v3-turbo (openai HF repo) | 1.01 s | 45.2 s | 40x | 2063 MB |
| transcribe-rs (meetily stack) | large-v3-turbo ggml | 0.39 s | 49.6 s | 36x | 2179 MB |
| whisper.cpp (Metal) | large-v3-turbo ggml | 0.39 s | 51.3 s | 35x | 2206 MB |
| mlx-whisper (piko today) | large-v3-turbo mlx | 0.43 s | 61.6 s | 29x | 1911 MB |
| mlx-whisper + word_timestamps | large-v3-turbo mlx | 0.43 s | 84.2 s | 21x | 2179 MB |

- Parakeet is **4–6x faster than any whisper-turbo engine** and parakeet-mlx uses
  **half the memory**.
- Whisper engines on the *same weights* land within ~20% of each other
  (whisper.cpp ≈ transcribe-rs > mlx-whisper); the Rust wrapper adds no overhead
  over raw whisper.cpp.
- Our current captions path (`word_timestamps=True`) costs ~35% extra
  (62 s → 84 s on 30 min).
- Parakeet OOMs Metal on unchunked 30-min audio (asks for a 32 GB buffer) —
  chunking (120 s / 15 s overlap) is mandatory and is what's measured here.

## Quality — the surprise

Coarse WER between engines is misleadingly high (35–43%) because the audio is
noisy real-world speech and **every whisper variant falls into hallucination
repetition loops** on hard segments, each in different places:

| engine | max consecutive 3-gram repeat |
|---|---|
| mlx-whisper | **18x** («окурек окурек окурек…») |
| mlx-whisper+wordts | 11x («и и и…») |
| whisper.cpp | 10x («спасибо спасибо…») |
| transcribe-rs | 1x (beam search, beam=3 — suppresses loops) |
| parakeet-mlx | **1x — no loops** |
| mlx-audio | **1x — no loops** |

The two parakeet runs agree with each other far more (17.6% WER) than any two
whisper engines do (34–43%) — whisper disagreement is mostly its own
hallucination noise. Eyeball check of excerpts: parakeet's Russian is coherent
and often *cleaner* than turbo (e.g. turbo: «дачи модерн глинер» vs parakeet:
«чем Modern Gleaner»). Parakeet v3 handles RU/EN code-switching well.

Caveats: single 30-min Russian screencast, no ground-truth transcript, greedy
whisper decode as shipped (loops could be partly mitigated with
`condition_on_previous_text=False` / VAD preprocessing).

## Realtime

RTF is a proxy: a 10 s chunk costs ~0.09 s on parakeet, ~0.3 s on whisper-turbo —
both fine for live captioning cadence. But parakeet-mlx additionally ships a true
streaming API (`transcribe_stream`, local attention context), which none of the
whisper batch engines offer out of the box.

## Recommendation for Piko

**Adopt `parakeet-tdt-0.6b-v3` via parakeet-mlx as the meeting-summary
transcription engine**, keep whisper as fallback for languages parakeet v3
doesn't cover (25 langs incl. EN/RU):

- 30-min meeting transcribed in ~16 s, under 1 GB RAM — leaves headroom for the
  summarization SLM running alongside.
- Python + MLX: drops into our existing backend with zero new toolchains
  (whisper.cpp/transcribe-rs would mean bundling a Rust/C++ binary for a 3x
  *slower* result).
- Cleaner Russian on noisy speech, no repetition loops, streaming API for live
  mode later.
- Word-level timestamps come native in its `AlignedResult` — potentially usable
  by the captions skill too.

mlx-audio note: its public `load_model` API keeps checkpoint dtype (fp32 →
2.8 GB RSS); loading its vendored parakeet `Model.from_pretrained(dtype=bf16)`
directly gives 8.4 s / 1.18 GB — quality identical (2% WER vs its fp32 run).
So mlx-audio's vendored decode loop is genuinely ~2x faster than parakeet-mlx
at the same dtype and RAM. Still not worth adopting the framework for meetings
(heavy dependency tree, previously rejected as unified engine, 16 s is already
far below the bar) — but the delta says parakeet-mlx's chunk merge/decode loop
has ~2x of recoverable headroom; port those optimizations if transcription
speed ever matters.

Whisper-turbo via mlx-audio (fp16, openai HF repo): 45.2 s — the fastest
whisper engine measured, edging out whisper.cpp (51 s) and mlx-whisper (62 s),
and its transcript had almost no repetition loops (max 2x). A bf16 variant
(weights re-cast, decoder patched — mlx-audio's whisper decode hardcodes fp16)
was *slower*, 68.8 s: bf16 whisper hallucinated more («и» 9x loop), triggering
temperature-fallback re-decodes. For parakeet the ranking flips: bf16 8.4 s vs
fp16 12.3 s vs fp32 10.8 s at identical output (2.1% WER fp16↔bf16, no loops) —
with a fixed compute graph and no autoregressive fallback, bf16 kernels are
~1.5x faster than fp16 here. Net: dtype speed is engine-specific — measure,
don't assume; each engine's native default (whisper fp16, parakeet bf16) was
the right one.
