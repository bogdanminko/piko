# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Piko** — an open-source local AI workspace for macOS, powered by small models. Everything runs locally on Apple Silicon. See [docs/PRODUCT.md](docs/PRODUCT.md) for the product context (who it's for, priorities, what not to build) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design direction: the core model is `Input → Artifact → Skill → Model → Result → Export`.

Currently implemented: the **captions skill** — burns "viral-style" animated subtitles (MrBeast/TikTok look) into videos. The next vertical is **Meeting Summary** (see PRODUCT.md); don't build agents, marketplaces, or extra inference providers before that ships.

Two layers communicating over a JSON protocol:

- **Python backend** (`src/piko/`) — mlx-whisper transcription, ASS subtitle generation (pysubs2), ffmpeg burn-in. Managed by `uv`.
- **SwiftUI frontend** (`Piko/`) — built with **SPM, not Xcode** (no .xcodeproj; builds with plain `swift build` and does not depend on Xcode being installed).

## Commands

```bash
# Python tests
uv run pytest -q                    # all
uv run pytest tests/test_semantic.py -q   # one file

# Backend smoke test (JSON protocol over stdin/stdout)
echo '{"command":"list_models"}' | uv run python -m piko.main

# Build + bundle + sign the app (SPM release build → build/Piko.app)
./scripts/make-app.sh
open build/Piko.app

# Swift compile check only
swift build

# Quality gate (also runs as a pre-commit hook and in CI)
uv run ruff check && uv run ruff format --check
uv run mypy
XCODE_DEFAULT_TOOLCHAIN_OVERRIDE=/Library/Developer/CommandLineTools swiftlint --strict
```

Lint/type/test gates: ruff + mypy (config in `pyproject.toml`), SwiftLint (`.swiftlint.yml`), pytest incl. protocol-contract tests (`tests/test_protocol.py` — checks every `emit()` key is decodable by `BackendMessage.swift` and that stdout stays JSON-only). Pre-commit (`.pre-commit-config.yaml`) runs all of the above plus gitleaks/shellcheck/large-file guard; CI (`.github/workflows/ci.yml`) runs on PRs and pushes to main. The `XCODE_DEFAULT_TOOLCHAIN_OVERRIDE` env var is needed for SwiftLint's SourceKit on CLT-only machines (no Xcode).

ffmpeg/ffprobe are hardcoded to `/opt/homebrew/bin/` (`src/piko/core/media.py`). The Swift side (`Piko/Services/BackendService.swift`) bootstraps the backend venv once with `uv sync --frozen` (stamp file `.venv/piko-uv.lock.stamp` holds the uv.lock contents the venv was built from; it re-syncs only when uv.lock changes) and then always launches `<root>/.venv/bin/python -m piko.main` directly — deliberately not `uv run`, so uv can never re-resolve or update anything at app launch.

All docs, code comments, and commit messages are in English (the project is open source).

## Architecture

### Backend layout (`src/piko/`)

```
main.py            # thin dispatcher: one JSON command from stdin → handler
protocol.py        # emit() — newline-delimited JSON to stdout
cache.py           # CACHE_DIR (~/Library/Caches/piko)
core/              # capabilities shared across skills
├── transcriber.py # mlx-whisper wrapper (stdout redirected to stderr)
└── media.py       # ffmpeg/ffprobe: probe, extract_audio, burn_subtitles
commands/          # protocol handlers, one module per area
├── transcribe.py  # transcribe + on-disk transcription cache
├── render.py      # render / process (drives the captions skill)
├── previews.py    # style_previews
└── models.py      # list/download/check Whisper models
skills/
└── captions/      # first skill: the whole subtitle pipeline
    ├── generator.py        # generate_subtitles() — orchestrates the steps
    ├── keyword_detector.py # prosody-based emphasis detection
    ├── semantic_colors.py  # color words → paint + emoji (EN+RU)
    ├── emoji_mapper.py / emoji_renderer.py
    ├── preview.py          # PNG preview strips
    └── styles/             # STYLES registry + BaseStyle + 5 styles
```

New skills (e.g. meeting summary) get their own `skills/<name>/` package and reuse `core/`.

### JSON protocol (the seam between Swift and Python)

Each command = one short-lived Python process. Swift writes one JSON command to stdin; Python emits newline-delimited JSON messages (`progress` / `result` / `error` / `models`) to stdout. **stdout is protocol-only** — mlx-whisper's prints are redirected to stderr in `core/transcriber.py`; never `print()` to stdout in the backend. Message schema lives in `src/piko/commands/` (emit sites) and `Piko/Models/BackendMessage.swift` (one big optional-field struct; keep the two in sync + CodingKeys for snake_case).

Commands: `process` (full pipeline, CLI convenience), `transcribe` (slow, cached), `render` (fast, repeatable), `style_previews`, `list_models`, `download_model`, `check_model`.

### Two-phase pipeline + caching

Transcription is decoupled from rendering so style/animation changes never re-run Whisper:

1. `transcribe` → cached JSON in `~/Library/Caches/piko/transcriptions/<sha1(path+mtime+model+lang)>.json`; returns `transcription_path`.
2. `render` → takes `transcription_path` + style + word_mode + highlight_color, generates .ass, burns with ffmpeg (~sub-second for short clips).

The Swift `VideoProcessorVM` additionally keeps a per-session render cache keyed by output path (which encodes style+mode+color), so switching back to an already-rendered combination swaps files instantly without calling the backend. The app never writes next to the user's video: renders and .ass files go to `~/Library/Caches/piko/renders/`, and the user exports explicitly via the Save Video… / Save Subtitles… buttons (NSSavePanel + copy). The sidebar's "Clear Cache" button wipes the whole `~/Library/Caches/piko` directory (style previews regenerate on the next `style_previews` call). The `piko_output/` default in `commands/render.py` only applies to CLI use without an explicit `output_path`.

### Captions skill (`src/piko/skills/captions/`)

Word-level Whisper timestamps flow through:
1. `keyword_detector.py` — emphasis detection via 3 prosody signals (confidence ≥0.92, pause ≥0.3s before, duration ≥1.5× median), 2-of-3 required, EN+RU stop words. No NLP/TF-IDF — importance comes from *how* a word is spoken.
2. `semantic_colors.py` — color words and color-associated objects ("зелёный"→green, fire→orange, рост→green 📈) get painted + emoji, **independent of keyword detection**. EN+RU via stem matching.
3. `styles/` — registry `STYLES` in `__init__.py`. `BaseStyle` owns the generic event generator with three `word_mode`s (static / reveal / highlight with configurable color); line-based styles (mrbeast, hormozi, minimal) only override `decorate_word()`/`word_text()` hooks. karaoke and tiktok override `generate_events()` entirely (built-in animation, word_mode is ignored for them — mirrored in Swift by `supportsWordMode`).

`generate_subtitles()` returns `(SSAFile, emoji_timeline)` — a tuple, not just the file.

### B-roll cut-ins (local, no network)

`render`/`process` accept `"broll": true`. Clips come from a user-managed
library at `~/Library/Application Support/Piko/BRoll/<concept>/*.mp4` —
folder names are canonical **English** concepts (e.g. `dog`, `fire`,
`green`); `CONCEPT_LEXICON` in `core/broll.py` maps each concept onto its
EN/RU/DE/FR keyword stems, so an English folder still fires on "собака" or
"Hund" (aliases.txt inside a folder adds extra keywords on top; matching
is stem-prefix, see `_matches()`). `canonical_concept()` folds free text in
any of those languages onto its concept name — `fetch_broll` uses it so
typing "лошадь" or "cheval" both land in the same `horse` folder instead of
forking duplicates. Folders from before this migration (Russian names) are
renamed to their canonical English name on first scan, merging into an
existing folder of that name if present (`_migrate_legacy_folders()`,
`LEGACY_FOLDER_NAMES`). The planner walks word timestamps (skip first 1.5s,
≥4s between inserts, ≤6 total, ~2.2s each), rotates clips per concept
across renders (state in the cache dir), composes full-frame cut-ins with
ffmpeg (`compose_broll`, audio untouched) and then burns subtitles on top.
The Swift toggle lives in the captions settings panel. `download_broll_pack`
(button "Get Starter Pack") fetches a curated set of openly licensed clips
(CC0/PD/CC BY only — Wikimedia Commons + NASA, manifest in
`commands/broll_pack.py`, includes a few color concepts that pair with
`semantic_colors.py`'s word painting), normalizes them (h264, no audio,
≤1280px, trimmed) and writes ATTRIBUTION.txt per concept folder.
`fetch_broll` (the "Fetch" row in the B-roll section) is the keyless
generic handle: searches Wikimedia Commons for any query with the same
license filter and downloads top hits into a concept folder. Deliberately
no stock APIs that need accounts/keys (Pexels etc.) — the user can always
drop manually downloaded clips into the folders instead.

### Emoji: never in ASS text

**libass cannot rasterize Apple Color Emoji** (renders tofu boxes) — this was tested exhaustively (fontsdir, direct font name, coretext provider). Emojis are therefore rendered to transparent PNGs via Pillow (`emoji_renderer.py`, `embedded_color=True`, cached in `~/Library/Caches/piko/emoji/`) and composited by ffmpeg `overlay` filters centered above the subtitle block (`burn_subtitles(emoji_overlays=...)`). The timeline is trimmed so consecutive emojis never stack on screen. Do not put emoji characters into ASS event text.

### Style previews

`style_previews` renders each style's sample line on a dark gradient (no emoji overlay) through the same ass ffmpeg pipeline (not a SwiftUI imitation), cached as PNG strips in `~/Library/Caches/piko/previews/`. Shown in the sidebar and in the result screen's style switcher. Regenerate with `{"command":"style_previews","params":{"force":true}}` after changing any style's look.

## Hard-won gotchas

- **SPM + AVKit**: `Package.swift` must keep `.linkedFramework("AVKit")`. SPM autolinks only the `_AVKit_SwiftUI` overlay; without AVKit itself the app crashes at runtime (`getSuperclassMetadata` abort) the moment `VideoPlayer` appears.
- **BackendService project-root discovery** walks up looking for `pyproject.toml` from the bundle path (covers `build/Piko.app` inside the repo) and from `#filePath` (covers bare-executable runs via Xcode/`swift run`, which build into DerivedData/`.build`). Both are dev-machine assumptions by design.
- **Swift concurrency**: `swift build` treats some Swift-6 concurrency issues as warnings; don't mutate captured locals inside the `MainActor.run` closures in VM stream loops.
- After changing UI state flow, remember `MainView` re-renders on changes of `selectedStyle`, `wordMode`, `highlightColorHex` via `.onChange` → `reRender()` (only when state is `.done`).
- Renaming/moving: project was renamed creit→piko in-place; if the venv or Swift `.build` cache misbehaves after a rename, delete `.venv`/`.build` and rebuild.
