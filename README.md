<div align="center">

# Piko

**Artifacts that finish the job.**

*Local AI, open source, and about twice as fast as Meetily.*

![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-MLX-ff6f00)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-f05138?logo=swift&logoColor=white)
![Python 3.13](https://img.shields.io/badge/Python-3.13-3776ab?logo=python&logoColor=white)
![No cloud](https://img.shields.io/badge/cloud-none-2ea043)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

</div>

---

You already know the artifact from Claude: you ask, and a real object comes
back — a document, a plan, a list of things to do. And then it stops there.
Getting it into the place where the work actually happens is your problem again.

Piko makes the same kind of artifact and carries it the rest of the way. Press
record before a call and you get a transcript, then a summary, then action items
— and those action items go into your calendar and your task tracker. No MCP
server, no API token, no cloud. Which model does the work is an implementation
detail; it runs on your Mac through [MLX](https://github.com/ml-explore/mlx),
and you can swap it.

## What's different

**Your side of the call is known, not guessed.** Piko records the microphone
and the system output as two separate tracks, so "you" versus "them" is decided
by which track carries the sound — physics, not a model that can be wrong.
Splitting the far end into individual people is the only part that needs a
model, and it is optional.

**Every claim points back at the recording.** Action items carry the timecode
they came from, and a `piko://` link that reopens that moment — in the app and
in whatever you exported to. A summary you cannot check is just a rumour with
better formatting.

**Re-running never destroys your edits.** The summary is derived and may be
regenerated at any time; corrections, ticked boxes and hand-added items live in
a separate overlay and are re-attached afterwards.

**The last mile needs no plumbing.** Markdown, `.ics`, `.csv`, Reminders and
Calendar (one system prompt, and it writes into the Google and Exchange accounts
your Mac already has), or a prefilled compose URL for Jira, GitHub, Linear,
Trello, Notion Calendar and friends. No MCP server to run, no token to paste, no
OAuth dance — and nothing leaves the machine until you press Create.

**Fast, and measured rather than claimed.** WER, speed and real memory use are
benchmarked on-device in [`bench/`](bench/README.md) — including the Rust and
ONNX runtimes Meetily is built on, which come out around 2-3× slower on the same
audio and the same model. The numbers the app shows you are the measured ones.

## Skills

| Skill | What it does |
|---|---|
| **Meeting Summary** | Records a call on two tracks, transcribes it, labels who spoke, writes a summary you can check, and sends the action items to your calendar or tracker |
| **Captions** | Burns viral-style animated subtitles into video — word-level timing, prosody-driven emphasis, semantic colouring, optional local B-roll cut-ins |

## Quick start

Requires an Apple Silicon Mac on macOS 14.4+, [uv](https://docs.astral.sh/uv/),
and ffmpeg (`brew install ffmpeg`).

```bash
git clone https://github.com/bogdanminko/piko.git
cd piko
./scripts/make-app.sh     # SPM release build, bundled and signed
open build/Piko.app
```

There is no Xcode project — the app builds with plain `swift build` and does not
need Xcode installed.

## How it works

Two layers over a small JSON protocol: a **SwiftUI** app for capture and UI, and
a **Python** backend for anything with a model in it. Each command is one
short-lived process — Swift writes a JSON request to stdin, Python streams
progress and results back on stdout.

```
Piko/            SwiftUI app — recording, UI, EventKit and file exports
src/piko/        Python backend — transcription, summarization, rendering
  core/            capabilities shared across skills (ASR, LLM, media, memory)
  skills/          one package per skill
  commands/        one protocol handler per area
bench/             on-device benchmarks behind the model choices
docs/              PRODUCT.md (what and for whom) · ARCHITECTURE.md (how)
```

## Status

Early and moving. Interfaces, models and file formats still change between
commits; the pieces described above work today, and the roadmap lives in
[docs/PRODUCT.md](docs/PRODUCT.md).

## License

[Apache 2.0](LICENSE).
