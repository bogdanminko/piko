# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Piko** — macOS app that burns "viral-style" animated subtitles (MrBeast/TikTok look) into videos, fully locally on Apple Silicon. Two layers communicating over a JSON protocol:

- **Python backend** (`src/piko/`) — mlx-whisper transcription, ASS subtitle generation (pysubs2), ffmpeg burn-in. Managed by `uv`.
- **SwiftUI frontend** (`Piko/`) — built with **SPM, not Xcode** (no .xcodeproj; Xcode is not installed on this machine, only Command Line Tools).

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
```

There is no linter configured. ffmpeg/ffprobe are hardcoded to `/opt/homebrew/bin/` (`src/piko/video_processor.py`); the Swift side launches the backend via `~/.local/bin/uv run --project <root> python -m piko.main` (`Piko/Services/BackendService.swift`).

## Architecture

### JSON protocol (the seam between Swift and Python)

Each command = one short-lived Python process. Swift writes one JSON command to stdin; Python emits newline-delimited JSON messages (`progress` / `result` / `error` / `models`) to stdout. **stdout is protocol-only** — mlx-whisper's prints are redirected to stderr in `transcriber.py`; never `print()` to stdout in the backend. Message schema lives in `src/piko/main.py` (emit sites) and `Piko/Models/BackendMessage.swift` (one big optional-field struct; keep the two in sync + CodingKeys for snake_case).

Commands: `process` (full pipeline, CLI convenience), `transcribe` (slow, cached), `render` (fast, repeatable), `style_previews`, `list_models`, `download_model`, `check_model`.

### Two-phase pipeline + caching

Transcription is decoupled from rendering so style/animation changes never re-run Whisper:

1. `transcribe` → cached JSON in `~/Library/Caches/piko/transcriptions/<sha1(path+mtime+model+lang)>.json`; returns `transcription_path`.
2. `render` → takes `transcription_path` + style + word_mode + highlight_color, generates .ass, burns with ffmpeg (~sub-second for short clips).

The Swift `VideoProcessorVM` additionally keeps a per-session render cache keyed by output path (which encodes style+mode+color), so switching back to an already-rendered combination swaps files instantly without calling the backend. Output goes to `piko_output/` next to the source video by default; user can override the folder (persisted in UserDefaults key `outputDirOverride`).

### Subtitle generation (`src/piko/subtitle_generator.py` → `styles/`)

Word-level Whisper timestamps flow through:
1. `keyword_detector.py` — emphasis detection via 3 prosody signals (confidence ≥0.92, pause ≥0.3s before, duration ≥1.5× median), 2-of-3 required, EN+RU stop words. No NLP/TF-IDF — importance comes from *how* a word is spoken.
2. `semantic_colors.py` — color words and color-associated objects ("зелёный"→green, fire→orange, рост→green 📈) get painted + emoji, **independent of keyword detection**. EN+RU via stem matching.
3. `styles/` — registry `STYLES` in `__init__.py`. `BaseStyle` owns the generic event generator with three `word_mode`s (static / reveal / highlight with configurable color); line-based styles (mrbeast, hormozi, minimal) only override `decorate_word()`/`word_text()` hooks. karaoke and tiktok override `generate_events()` entirely (built-in animation, word_mode is ignored for them — mirrored in Swift by `supportsWordMode`).

`generate_subtitles()` returns `(SSAFile, emoji_timeline)` — a tuple, not just the file.

### Emoji: never in ASS text

**libass cannot rasterize Apple Color Emoji** (renders tofu boxes) — this was tested exhaustively (fontsdir, direct font name, coretext provider). Emojis are therefore rendered to transparent PNGs via Pillow (`emoji_renderer.py`, `embedded_color=True`, cached in `~/Library/Caches/piko/emoji/`) and composited by ffmpeg `overlay` filters centered above the subtitle block (`burn_subtitles(emoji_overlays=...)`). The timeline is trimmed so consecutive emojis never stack on screen. Do not put emoji characters into ASS event text.

### Style previews

`style_previews` renders each style's sample line on black through the same ass+overlay ffmpeg pipeline (not a SwiftUI imitation), cached as PNG strips in `~/Library/Caches/piko/previews/`. Shown in the sidebar and in the result screen's style switcher. Regenerate with `{"command":"style_previews","params":{"force":true}}` after changing any style's look.

## Hard-won gotchas

- **SPM + AVKit**: `Package.swift` must keep `.linkedFramework("AVKit")`. SPM autolinks only the `_AVKit_SwiftUI` overlay; without AVKit itself the app crashes at runtime (`getSuperclassMetadata` abort) the moment `VideoPlayer` appears.
- **BackendService project-root discovery** walks up from the bundle path looking for `pyproject.toml` — the app only works when `build/Piko.app` lives inside the repo (dev setup by design).
- **Swift concurrency**: `swift build` treats some Swift-6 concurrency issues as warnings; don't mutate captured locals inside the `MainActor.run` closures in VM stream loops.
- After changing UI state flow, remember `MainView` re-renders on changes of `selectedStyle`, `wordMode`, `highlightColorHex` via `.onChange` → `reRender()` (only when state is `.done`).
- Renaming/moving: project was renamed creit→piko in-place; the repo folder name may still be `creit` — nothing inside depends on the folder name.
