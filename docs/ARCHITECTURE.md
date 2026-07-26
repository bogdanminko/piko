# Piko — Architecture Direction

*This document describes where the design is headed, not what is promised.
When it conflicts with [PRODUCT.md](PRODUCT.md) priorities, PRODUCT.md wins.*

## Core model

```text
Input → Artifact → Skill → Model → Result → Export
```

## Artifact

Any user material: video, audio, transcript, document, image, a set of files.
An Artifact stores the original, its metadata, and derived results —
transcript, timecodes, subtitles, summaries, exports. Derived results are
cached and never recomputed when only presentation settings change (this is
already how the captions skill works: transcription is cached separately from
rendering).

## Skill

A finished operation with a predictable result: Generate Subtitles, Style
Captions, Summarize Meeting, Extract Action Items, Find Highlights, Create
Chapters. A Skill defines its inputs, prompt, processing stages, and result
format. It requests **model capabilities** (summarization, structured output,
vision, context length) — never a concrete model name.

In code: each skill is a `skills/<name>/` package reusing `core/`
(transcription, media). See CLAUDE.md for the current layout.

## Model runtime

The tier registry maps **role → concrete model** in exactly one place on the
Python side. The Swift UI and the JSON protocol only ever speak tiers
(`fast` / `balanced` / `quality`), so swapping a tier's underlying model never
touches the frontend. Each registry entry records the HF repo, its size, and
the minimum inference-library version it needs.

Runtime ladder, in order of adoption:

1. **Embedded MLX** (mlx-whisper today, mlx-lm for SLMs) — the only runtime
   for v1; keeps the zero-setup promise.
2. **Custom OpenAI-compatible endpoint** (LM Studio, Ollama, remote) — later,
   as an advanced setting; one URL field, not a provider system.
3. **Apple Foundation Models** — when the API and models justify it.

## Assistants (future)

An assistant = system prompt + a set of skills + a model + permissions. Manual
mode runs skills directly; Agent Mode lets the assistant chain them. Both use
the same engine. **Not before Meeting Summary ships** — see PRODUCT.md.

## UI direction

v1 is one window: "Drop anything" → applicable skills → result. Sections like
Library (all artifacts and results) and Runs (process history) only earn their
place once there are enough skills and artifacts to need them; Assistants and
a Models manager come later still.
