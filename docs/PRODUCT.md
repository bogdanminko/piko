# Piko — Product Context

## What Piko is

Piko is an open-source, local-first macOS app that turns local AI models into understandable tools for working with video, audio, text, and files.

**Small local AI for your Mac.**

The user can either:

1. Pick a specific tool themselves and fine-tune the result.
2. Hand the material to an assistant that selects and chains the right tools on its own.

All data stays on the Mac by default.

## What Piko is not

Piko is not yet another LLM chat UI and not a replacement for LM Studio.

The core unit of the product is not a message — it is a **result**:

- a video with subtitles;
- a transcript;
- a meeting summary;
- a list of decisions and action items;
- study notes;
- chapters and highlights;
- a transformed or analyzed file.

## Core product model

```text
Input → Artifact → Skill → Model → Result → Export
```

### Artifact

Any user material:

- video;
- audio;
- transcript;
- document;
- image;
- a set of files.

An Artifact stores the original, its metadata, and derived results: transcript, timecodes, subtitles, summaries, and exports.

### Skill

A finished operation with a predictable result:

- Generate Subtitles
- Style Captions
- Summarize Meeting
- Extract Action Items
- Find Highlights
- Chat With Video
- Create Chapters

A Skill defines its inputs, model, prompt, processing stages, and result format.

### Assistant

An Assistant consists of:

- a system prompt;
- a set of available skills;
- a selected model;
- memory and settings;
- permissions.

In normal mode the user runs skills manually. In Agent Mode the assistant picks and chains them itself. Both run on the same engine underneath.

## What already exists

The first working vertical scenario:

```text
Video → Transcription → Timed Captions → Styled Video
```

It should not be treated as a separate app. It is the first skill inside the overall Piko system.

## Next vertical scenario

**Meeting Summary** is the second end-to-end feature:

```text
Audio / Video
→ Transcription
→ Semantic Segmentation
→ Structured Summary
→ Decisions and Action Items
→ Editable Result
→ Markdown / JSON Export
```

Result format:

- brief summary;
- main topics;
- decisions made;
- action items with assignee and due date when stated;
- open questions;
- key quotes;
- links to the corresponding timecodes.

Every claim should, whenever possible, be linked to a fragment of the transcript. This matters more than polished prose: the user must be able to verify the result.

## Model Runtime

Piko must not depend on a single inference engine.

Base interface:

```text
ModelRuntime
├── Apple Foundation Models
├── Embedded MLX
└── OpenAI-compatible server
    ├── LM Studio
    └── other local servers
```

A Skill requests model capabilities, not a specific model name:

- summarization;
- structured output;
- vision;
- tool calling;
- required context length.

## First-version UI

Main sections:

- **Library** — all added materials and results.
- **Tools** — manual skill launcher.
- **Assistants** — downloaded or user-created assistants.
- **Models** — installed models and runtimes.
- **Runs** — active and completed processes.

The main screen can start with a single action:

> Drop anything.

After a file is added, Piko shows the applicable skills or offers to hand the material to an assistant.

## Nearest milestone

The user drops in an hour-long call recording and gets, fully locally:

- a transcript with timecodes;
- a verifiable summary;
- decisions;
- action items;
- a Markdown file;
- the ability to jump from a summary item to the source moment in the recording.

This is the first scenario that simultaneously validates the architecture of artifacts, skills, models, run history, and export.

## What NOT to build yet

Until Meeting Summary is finished, do not build:

- a universal autonomous agent;
- a travel assistant;
- a marketplace;
- cloud sync;
- complex long-term memory;
- ten inference providers;
- model fine-tuning from the UI.

## Own SLM work

Lock down the evaluation pipeline first; tune the model only after that.

Order of work:

1. Collect 30–50 diverse meetings.
2. Annotate decisions, action items, topics, and factual errors.
3. Compare several models and prompts.
4. Save Piko's failed outputs as training examples.
5. Build a teacher-generated dataset and manually verify a portion of it.
6. Run SFT/LoRA on a model up to 2B parameters.
7. Release the model, adapters, quantizations, and eval results as separate Hugging Face repositories.

Key metrics:

- factual precision;
- coverage of decisions and action items;
- correctness of assignees and due dates;
- groundedness relative to the transcript;
- structural stability;
- latency;
- peak memory;
- model size.

## Positioning

**Piko is an open-source local AI workspace for macOS, powered by small models.**

Short formula:

> **Small models. Useful skills. Everything stays on your Mac.**

Product mechanic:

> **Do it yourself—or hand it off.**
