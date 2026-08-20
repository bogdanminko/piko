# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Personal data: do not read it

`~/Library/Application Support/Piko/` is the user's own data — real meeting
audio, transcripts, summaries, people, links. **Never read, list, print or copy
anything under it without the user asking for that specific thing first.** It is
not test material, and "I need a realistic case to verify against" is not a
reason: ask for a file the user chooses to hand over, or build a synthetic one.

This covers reading a recording folder to check a pipeline's output, printing
transcript lines to judge a result, and enumerating recordings to find something
to test on — all of it needs explicit acceptance first.

Write access to that directory is a separate question and is what the app itself
does; the rule here is about Claude reading it. `~/Library/Caches/piko/` is
derived data and not covered.

## What this is

**Piko** — artifacts that finish the job: open source, local to the Mac. An artifact you can ask for is half a result, so every skill runs from the request through to the place the work actually lands. Everything runs locally on Apple Silicon. See [docs/PRODUCT.md](docs/PRODUCT.md) for the product context (who it's for, priorities, what not to build) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design direction: the core model is `Input → Artifact → Skill → Model → Result → Export`.

Two skills are implemented. **Meeting Summary** is the further along of the two and the current focus: record a call, transcribe it, attribute speakers, summarize, and export action items. **Captions** came first — it burns "viral-style" animated subtitles (MrBeast/TikTok look) into videos. Don't build agents, marketplaces, or extra inference providers on top of either.

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
# ...but once a copy is installed, the script *moves* the bundle there rather
# than leaving a second one behind (a stale duplicate is free to answer a
# piko:// link), so build/Piko.app is gone and the script prints the real
# command instead:
open -a /Applications/Piko.app

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
├── meeting.py     # finalize_recording / transcribe_meeting
├── previews.py    # style_previews
└── models.py      # list/download/check Whisper models
skills/
├── meeting/       # recorded call → speaker-labelled transcript
│   ├── audio.py      # raw tracks → m4a + mix, decode to samples
│   └── speakers.py   # who spoke, by comparing track energy
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

Each command = one short-lived Python process — **except the ones whose cost is
the model**, which share one resident process (see "The model stays loaded").
Swift writes one JSON command to stdin; Python emits newline-delimited JSON messages (`progress` / `result` / `error` / `models`) to stdout. **stdout is protocol-only** — mlx-whisper's prints are redirected to stderr in `core/transcriber.py`; never `print()` to stdout in the backend. Message schema lives in `src/piko/commands/` (emit sites) and `Piko/Models/BackendMessage.swift` (one big optional-field struct; keep the two in sync + CodingKeys for snake_case).

Commands: `process` (full pipeline, CLI convenience), `transcribe` (slow, cached), `render` (fast, repeatable), `finalize_recording`, `import_recording`, `transcribe_meeting`, `summarize_meeting`, `style_previews`, `list_models`, `download_model`, `check_model`.

### Two-phase pipeline + caching

Transcription is decoupled from rendering so style/animation changes never re-run Whisper:

1. `transcribe` → cached JSON in `~/Library/Caches/piko/transcriptions/<sha1(path+mtime+model+lang)>.json`; returns `transcription_path`.
2. `render` → takes `transcription_path` + style + word_mode + highlight_color, generates .ass, burns with ffmpeg (~sub-second for short clips).

The Swift `VideoProcessorVM` additionally keeps a per-session render cache keyed by output path (which encodes style+mode+color+edits), so switching back to an already-rendered combination swaps files instantly without calling the backend. The app never writes next to the user's video: renders and .ass files go to `~/Library/Caches/piko/renders/`, and the user exports explicitly (NSSavePanel + copy). The sidebar's "Clear Cache" button wipes the whole `~/Library/Caches/piko` directory (style previews regenerate on the next `style_previews` call). The `piko_output/` default in `commands/render.py` only applies to CLI use without an explicit `output_path`.

**The burn is asked for, never assumed.** Dropping a file starts the
transcription and stops there (`ProcessingState.transcribed`): parakeet runs
around 190× realtime, so the words are on screen in seconds, while the burn is
a full re-encode of the whole video. Spending that before the user has read a
single word meant a misheard name could not be caught until after the expensive
part — and could not be fixed at all. Reaching `.transcribed` also fires one
`subtitle_only` render (ffprobe plus three small files, no encoder), so `.srt`,
`.vtt` and `.ass` exist immediately: the cheapest rung of the export ladder must
never sit behind the dearest. `.srt` is what every platform and editor reads;
`.ass` is the only one that carries the look, and the button that said
"Export .srt…" used to hand over an `.ass`.

**Corrections are an overlay, not an edit** (`Piko/Models/CaptionEdits.swift`,
`CaptionTranscript.swift`). The cached transcription stays exactly as the model
wrote it; a corrected line goes into
`~/Library/Application Support/Piko/CaptionEdits/<sha256(video path)>.json`,
and `CaptionTranscriptComposer` writes the *composition* of the two to a
`.edited.json` beside the cache entry, which is what `transcription_path`
points at for that render. Same arrangement as `SummaryEdits` /
`ComposedSummary` and for the same reason: re-transcribing must not be able to
destroy typed text. Application Support rather than Caches, so "Clear Cache"
cannot take it either. Edits re-attach by anchor (|Δstart| ≤ 3 s, ≥ 0.5 word
overlap with what the model originally said); what does not re-attach stays in
the file, unapplied and counted in the header, rather than being dropped. The
edit unit is the line — nobody clicks a word to fix a name, they retype the
sentence — and a same-length rewrite keeps every original per-word key
(including `probability`, which keyword detection reads), while a different
length re-times its words across the line's own span. Typing back exactly what
was generated drops the override instead of storing a copy of it.

Long runs are cancellable: `VideoProcessorVM` owns the task, and ending the
stream terminates the Python process through `continuation.onTermination` in
`BackendService`.

### Meeting recording (Swift capture → speaker-labelled transcript)

The first half of the Meeting Summary vertical. Capture is entirely Swift
(`Piko/Services/Recording/`), the backend takes over at Stop.

**Two tracks, always.** The microphone (`MicrophoneCapture`, AVAudioEngine tap)
and the system output (`SystemAudioTap`) are written to *separate* files. That
is the whole trick behind speaker attribution: `skills/meeting/speakers.py`
compares per-segment energy between the tracks instead of running diarization —
"me" is the mic side, "them" is everything coming out of the call. It separates
sides, not individual people, and that limit is deliberate.

**System audio uses a Core Audio process tap**, not ScreenCaptureKit: a tap
needs only the Audio Capture grant (`NSAudioCaptureUsageDescription`), while
SCStream would demand full Screen Recording plus macOS 15's recurring
re-approval nag. The shape Core Audio actually accepts: a global
`CATapDescription` becomes a *sub-tap* of a private aggregate device whose main
sub-device is the current default output, and an IOProc on that aggregate
delivers the mixdown. Tap-only aggregates and AVAudioEngine-on-aggregate both
fail *silently* (zero samples). The tap is bound to one output device, so
`MeetingRecorder` rebuilds it when the default output changes mid-call.

**On-disk shape** — `~/Library/Application Support/Piko/Recordings/<id>/`
(user data: "Clear Cache" must never touch it). While recording:
`mic.pcm` / `system.pcm`, raw 16 kHz mono s16le — header-less on purpose, so a
crash leaves a fully readable file, and no encoder sits on the capture path.
`RecordingSession` drains both ring buffers every 100 ms and pads silence
against a wall clock, which is what keeps the two tracks sample-aligned.

**After Stop**: `finalize_recording` mixes the raw tracks into `meeting.m4a`,
encodes each side to `mic.m4a` / `system.m4a`, deletes the raw PCM and updates
`meta.json`; `transcribe_meeting` transcribes the *mix only* (one Whisper pass,
reusing `transcribe.transcribe_video` and its cache), then attributes each
segment and writes `transcript.json`. Both are idempotent.

**Import** (`import_recording`, button + drop target on the Recordings card)
takes any file ffmpeg can decode — mp4, mov, mkv, m4a, mp3, wav, opus — and
extracts *only its audio* into a meeting folder (`-vn`), so the original is
never copied or modified and an hour of screen capture costs a few megabytes.
From there it is an ordinary meeting, minus the side tracks: attribution has
nothing to compare, so every segment is labelled `unknown` / "Speaker" instead
of a guessed "You".

`transcript.json` (`{version, language, duration, speakers, segments[]}` with
`start`/`end`/`speaker`/`text`/`speaker_confidence`) is the seam the
summarization step consumes — it should read that file, not the audio.

**Notes are the one meeting text that is not an overlay.** `MeetingNotesCard`
sits under `RecordingBar`, so it appears in both places that bar does — the
conversation and the expanded meeting screen — and a line typed into it is
stamped with `recorder.elapsed`, which excludes paused time and is therefore
the *audio's* axis rather than the wall clock's. That is what lets a note be
clicked to play from where it was taken, sit in the transcript at the moment it
was written (`TranscriptEntry.merge`), and be anchored to a transcript line
number for the model. Nothing generates a note, so unlike `SummaryEdits` there
is no generated version to compose against and nothing a rerun could destroy:
`notes.json` in the meeting folder is simply what was typed, written on each
keystroke's Enter (a call is exactly where "save at the end" loses everything)
and read but never written by the backend. Untimed notes are real — an import
has no clock, and a line added before Summarize is worth the same — they just
cannot be citations, so `anchor_notes` leaves their `ref` null and
`TranscriptEntry.merge` keeps them out of the transcript rather than inventing
a second for them.

The prompts give a note **authority over the transcript** (`NOTES_RULES` in
`skills/meeting/summary.py`): it is the only input in the pipeline a person
actually wrote, so where a typed name and a heard one disagree it is the ASR
that is wrong. The rules and the `<user_notes>` block are added only to calls
that have notes — a rule about a tag that is not in the message is an
invitation to invent one. A chunk is given only the notes anchored to a line it
holds, since a note citing a number that chunk cannot see is exactly the
invented `ref` the module exists to prevent; the reduce step is given all of
them, so a note in a chunk whose extraction failed is not lost. A summary is
still cached, so notes added after one was written do not silently invalidate
it — the toolbar says how many came late and leaves the rerun to the reader.

**The sample rate comes from the buffers, not from the engine.**
`AVAudioEngine.inputNode.outputFormat(forBus:)` read before `engine.start()`
reports 48 kHz whatever the device does, and AirPods on a call run their
microphone at 16 or 24 kHz. Believing the engine made `PCMTrackWriter` resample
48→16 on audio that was already 16: a third of the frames written, and the drain
loop's silence padding dutifully made up the deficit against the wall clock. The
file came out exactly the right length — 49 minutes — with every voice three
times too fast and the gaps filled with quiet. Padding is what turned a wrong
rate into a *plausible* file, which is why it is the more dangerous half of that
pair. `MicrophoneCapture` installs its tap with a `nil` format and reports the
rate off the first buffer that disagrees (`onSampleRateChanged`); a buffer
carries its own format and is the only account that cannot be wrong.

**Permissions** live in `RecordingPermissions`. Microphone has a real API;
system audio has none — a tap without the grant "succeeds" and returns silence
forever, so the check is empirical: start a tap, play a short sound, see if the
tap heard it. That same first tap creation is what raises the macOS dialog.

### The workspace: one entrance, one artifact

`ARCHITECTURE.md` says `Input → Artifact → Skill → Model → Result → Export`,
and the UI used not to implement it: Captions and Meeting Summary were sibling
tabs, so the app asked what kind of work this was *before* anything had looked
at the file. The same mp4 was "a video needing subtitles" in one tab and "a
call needing a summary" in the other. Two entrances is what made one product
read as two, and it is what forces a captions vertical to grow its own editor.

There is now one working screen, `ArtifactScreen`, and the app opens on it.
`AppScreen` is `artifact / library / models / appearance`; which artifact is
open is `AppState.focus` (`none / meeting / video`), and **everything that
opens something goes through `AppState.show(_:)`** — Library, Recent, a
`piko://` link, a drop, starting a recording. Library is history, not a way in.

**Switching reading does not re-transcribe.** The two halves hand the ASR
cache different files — captions transcribe the video itself, a meeting
transcribes the `meeting.m4a` extracted from it — so the same speech missed
the cache and paid for a second full pass. "Summarise as a Call" therefore
carries the transcription it already has (`transcribe_meeting`'s
`transcription_path` → `_reuse_transcription`), and the meeting is built from
those segments without touching the model. Strictly a reuse: a missing or
unreadable file falls through to transcribing properly, and `force` outranks
it, since `force` exists for a transcript that came out wrong. Attribution
loses nothing — an import has no side tracks, so every segment was `unknown`
either way.

**The pipeline is read off the file, not asked for** (`ArtifactRouting`): no
picture → a call; a picture but longer than ten minutes → a call (a screen
share is a conversation that happens to have video); otherwise a clip to
caption. Both signals are metadata, so the guess is free. It is never hidden:
the video header carries "Summarise as a Call", so being wrong costs one click
instead of a re-drop. The reverse direction is deliberately absent — an
imported meeting keeps only extracted audio (`-vn`), so there is no picture
left to burn into.

**The empty workspace explains itself, in the shape people already know.**
`WorkspaceChatView` + `WorkspaceChatVM` put a conversation beside the drop
card. Three rules keep it from becoming a chatbot, which `PRODUCT.md` rules
out: the composer is **locked** until the user has asked the one question
offered to them ("What can you do?") — an empty box in front of someone who
does not yet know what the app does invites exactly the request it cannot
honour; the first answer is **written, not generated**, and typed out at
reading speed (`WorkspaceChatVM.capabilities`); and the seconds that takes are
the seconds the local model spends becoming resident, because asking fires
`SummarizerVM.warmup()`. Every later question goes to the model through the
`chat` command, which streams `{"type": "chat", "delta": …}` tokens.

**The work happens in the thread, not on another screen.** Handing a file to
the workspace changes nothing about where you are: the file appears as a chip,
the pipeline starts behind it, and its progress, transcript and exports render
as live cards *in the conversation* (`ChatWorkCards.swift`, marked by
`ChatTurn.Payload`). The cards hold no state — each reads the view model that
is actually running, so a card from four minutes ago still shows the truth
rather than a snapshot. A chat that collects a file and then throws you onto a
different screen has made itself a lobby.

**A session owns its artifacts** (`Piko/ViewModels/ChatSession.swift`). The app
had exactly one `WorkspaceChatVM` and one `VideoProcessorVM`, which means it had
one session pretending to be many: open a recording from history and its
artifacts joined whatever conversation happened to be on screen, because there
was nowhere else for them to be. A thread and the things it produced are the
same object, so `ChatSession` holds the chat, the captions run, which recording
it is about and where the reader had the panel; `SessionStore` holds the list
and `current`. `MeetingVM` is deliberately *not* per session — one recorder and
one folder of recordings on this Mac make the library app-level — so a session
stores the recording's id and `MainView.syncMeeting()` selects it on the way in,
writing back through `onChange(of: meeting.selectedID)`.

Two rules keep the bleed out. A file handed to a session that has already done
work opens a **new** session rather than landing on top (`ArtifactRouting.open`),
and anything opened from history opens **its own** session — the one already
holding it if there is one (`session(holdingMeeting:)` / `holdingVideo:`),
otherwise a fresh one. Reaching into the Library must not change what the thread
you were reading is about. Sessions are in memory only for now: every artifact
they point at is already on disk and in the Library, so a quit costs the wording
around the work and not the work.

The sidebar lists **chats**, not artifacts. Recent used to list recordings and
captioned videos, which made it a second Library and left the conversation you
were actually in unnamed and unreachable — which is why the workspace header
needed a "Reopen" pill at all. With the chats listed, going back is where going
anywhere already is, and the pill is gone. "New session" is a button, not a
menu: asking *what kind of work is this* before you have a file in hand is the
entrance the workspace was built to remove.

**The workspace is always the conversation.** `ArtifactScreen` used to switch
on `AppState.focus` and render a module screen — drop a video and you were on a
transcriber, open a call from Library and you were on a summary page. That is
how one product went back to reading as several, and it made `focus` two things
at once: which pipeline a file belongs to, and which screen you are looking at.
It is only the first now. `show(_:)` loads an artifact into the session and
never navigates; every entrance (drop, Choose File…, a slash command, the
sidebar's New menu, Recent, Library, `piko://`) goes through
`ArtifactRouting.open(_:as:into:)`, which also puts the file in the thread as a
chip — a file that arrives from the sidebar and is never mentioned in the
conversation is a file the session does not know it has. `as:` overrides the
metadata guess, which is what keeps `/captions` on the captions pipeline: the
guess reads anything over ten minutes as a call, right for a drop and wrong for
an order.

**The modules are what the panel expands into.** `ArtifactSidePanel` has two
sizes. Docked, it is the compact reading — transcript, summary, result.
Expanded (the ⤢ in its header) it takes the whole pane and renders
`CaptionsScreen` or `MeetingSummaryView` in full, header and settings rail and
recordings list included, with one strip above it back to the conversation.
Those screens were the app before the workspace was and the work in them is
real; what was wrong was *arriving* at them instead of at the session. As the
far end of one panel they are what a reader asked for rather than where a file
was sent.

**A result is a card in the thread; the card opens it beside the thread.**
Two kinds of thing land in a conversation and they are not the same kind. A run
in progress and a choice being offered are *moments* — `ChatJobCard`,
`ChatStyleCard`, `ChatBurnProgressCard` render inline at full size, because
that is what the conversation is about right now. A finished result is an
**artifact** (`WorkspaceArtifact`): it gets an `ArtifactCard` — icon, name, one
line of "how big is it" — and clicking it opens the real thing in
`ArtifactSidePanel` to the right of the chat. Four hundred transcript lines in
a bubble is how a chat stops being one.

The panel that preceded this was **docked** under the messages, and that was
the mistake. A permanent second region in the same column is a split window
wearing a message's clothes: the conversation and the artifact both wanted
height, `VStack` split the shortfall between them, and each ended up showing a
line and a half — for a call, a transcript *and* a summary stacked inside that
same squeezed box. The panel is now a side pane that **closes**, and closing it
gives the full width back to the chat. It shows one artifact at a time, chosen
either from the card that announced it or from the rail of everything the
session has made, and each artifact renders the view that already existed for
it (`TranscriptView`, `ChatResultCard`, `ChatMeetingTranscriptCard`,
`MeetingSummaryColumn`). The available list is *derived* from the view models
on every pass, same rule as the Library: a cancelled burn or a reset cannot
leave a card pointing at nothing. Nothing navigates — styling, burning, playing
the result, summarising a call, recording one (`RecordingBar` appears in the
workspace) all still happen here.

**Long lists are `LazyVStack`, without exception.** An hour-long call is
several hundred segments of wrapped text; a plain `VStack` lays out every one
of them on every pass to put five on screen. That is main-thread layout, not
compute, so it reads as a stuttering scroll on an idle machine — which is
exactly how it was reported. The same rule is why the thread's auto-scroll
animates on a new turn and not on a landing token: animating to the same anchor
thirty times a second is an animation fighting itself.

**Most of what is typed needs no model.** "Summarise this" after a drop is a
button somebody typed; sending it to an LLM spends seconds to produce a
paragraph explaining how to press that button. `WorkspaceChatVM.Intent` matches
a short list (summarise / subtitles / burn / captions, EN+RU stems) and runs
the thing, which also works with no model downloaded and cannot hallucinate.
Everything unmatched still goes to the model, and the model is told what is
loaded (`context` on the `chat` command) — without that it tells people to drop
a file they dropped a minute ago.

What is *not* faked: the design called for transcript lines appearing as they
are recognised. The ASR reports percentages, not text, so the transcript card
appears when the pass finishes and is labelled accordingly. Showing a step
panel with invented lines would be decoration wearing the clothes of a feature.

**The conversation is the drop target.** A file dropped into it — or picked
with the paperclip — appears as a chip in a turn of its own, is acknowledged in
writing, and opens as an artifact a beat later (long enough that the chip is
seen; routing itself only reads metadata). There is deliberately no separate
drop panel beside the chat: a chat that says "drop the file here" and then does
not take it is the one thing an assistant must never do, and that is exactly
what the side panel made the model into. The capability sheet now states that
files arrive this way, so the model saying so is a fact rather than a
hallucination. This is also the difference worth having — a cloud assistant
given an mp4 can only offer to read a transcript you produce elsewhere.

Both answers come from one capability sheet, and that is the whole point:
`CAPABILITIES` in `src/piko/commands/chat.py` is the system prompt, it lists
only shipped features, and it names the things Piko cannot do so the model
refuses them instead of inventing them. Add to it when a skill ships, never
when one is planned — a local assistant confidently promising a feature is
worse than one that says no. Slash commands (`ChatCommand.all`) mirror
`COMMAND_SHEET` in the same file, and each one *does* the thing rather than
describing it.

**Every screen you can arrive at has a way out.** The workspace header carries
a back chevron to the empty workspace (`ScreenHeader.onBack`), shut with a
stated reason while a recording or a run is in flight — Stop and Cancel live on
those screens and nowhere else, so leaving would strand them. The sidebar's New
menu (`+` beside the Workspace label, and on the collapsed rail) is the same
escape from anywhere at all: Record a Call, Open a File…, Empty Workspace. It is
a menu rather than a bare `+` because a plus would have to guess which of the
two was meant. Backing out discards nothing, so the empty workspace offers
"Back to <name>" for whatever is still loaded.

Navigation no longer sweeps state. The old Captions tab reset itself whenever
you left it, which was defensible when a screen was a mode; in a workspace the
open artifact *is* the state, and a walk to Library and back must not discard a
finished render or an uncommitted correction.

`TranscriptView` is built from the same pieces as the meeting transcript —
`ThemedCard`, `SectionLabel`, `Timecode`, hairline-separated rows, the same
type sizes — because it is the same thing on screen. Two dialects of one view
is how a single app starts looking like two.

### Library: one session history over both verticals

The Library screen (`LibraryView` + `LibraryRow`, model in `Models/LibraryItem.swift`)
is a *derived* view, never a third store: it joins the two histories that already
exist — meetings (folders under `Application Support/Piko/Recordings`, enumerated
by `MeetingLibrary.list()`) and captions runs (`history.json`, `HistoryStore`) —
so a recording is history the moment it is saved, with nothing to keep in sync.
A row's stage (Recorded → Transcribed → Summarized, or Captioned) is read from the
files on disk on every scan (`MeetingLibrary.hasTranscript/hasSummary`) rather than
stored, so a rerun or a folder deleted from Finder can't leave a stale badge.
Rows group by calendar day, open in the workspace on that artifact
(`AppState.show(_:)`), and expose Rename, Reveal in Finder, Export Markdown
(the *composed* summary, edits included) and delete.
Deleting a captions entry only forgets the run; deleting a meeting destroys
audio, so it is the one action behind a confirm — and it is absent from the
sidebar entirely. The sidebar's Recent (`SidebarRecent`) is the same list,
truncated.

**Titles are generated, so they are editable.** A recorded call is named after
its clock time and everything else after the file it came from, which makes a
list of them unreadable by Friday. `EditableTitle` (hover the name → pencil, or
Rename in the row menu; Enter and clicking away commit, Escape abandons, an
empty field is a cancel) is the same control in all three places the name
appears — Library row, sidebar Recent, the Recordings card on Meeting Summary.
It writes into the record itself rather than an alias beside it: `title` in
`meta.json` for a meeting (`MeetingVM.rename`), the history entry for a captions
run (`HistoryStore.rename`), so one edit changes every list at once. Nothing
regenerates over it — the backend only rewrites the keys it produces and leaves
`title` alone, and `HistoryStore.record` reuses an existing entry's title
instead of re-deriving it from the file name on a rerun.

### Action items: edits overlay, Reminders, `piko://`

`summarize_meeting` writes `summary.json` and may rewrite it on any rerun, so it
stays strictly derived. Everything a person does to that summary — corrected
wording, ticked boxes, deleted or hand-added items, where a task was exported —
goes into **`summary.edits.json`** beside it (`Piko/Models/SummaryEdits.swift`,
loaded by `MeetingLibrary`, mutated only through `MeetingVM+Edits.swift`). The
screen renders `ComposedSummary.make(summary, edits:)`, the composition of the
two (`Piko/Models/ComposedSummary.swift` — what is rendered, never written; the
file next door is what is stored); a rerun therefore cannot destroy an edit. Edits re-attach to regenerated
items by anchor (same list, |Δstart| ≤ 15 s, ≥ 0.5 word overlap) — a rerun cites
a neighbouring line, not a different minute. What does not re-attach becomes an
`orphaned` row rather than being dropped: showing one stale row is recoverable,
deleting text a person typed is not. `start` is the one field with no editor —
a timecode is a citation, not a field.

Deadlines are resolved to real dates in the backend (`resolve_due_dates`),
anchored on the recording's own `started_at`, never on today. The spoken phrase
stays in `due` as the evidence; `due_date` / `due_time` are the suggestion, and
are absent whenever nothing resolved — the same null-over-guess rule as
timecodes.

### The three fields a transcript cannot answer

Owner and deadline are generated whenever somebody said them out loud, and that
is where the model's authority ends: half the tasks agreed on a call name no
owner, "by Friday" is a phrase before it is a date, and nobody reads a Jira key
into a meeting. So each is editable, together, in one popover off the row
(`ItemDetailsPopover`, reached from the assignee chip, the date, or the row
menu). The composition rules are what make that safe — see below.

**nil is not empty.** Every overridable field (`owner`, `due`, `dueDate`,
`dueTime`, `epic`) is a `String?` where nil means "the model's answer stands"
and `""` means "the user deleted it" (`SummaryEdits.override`). Without the
second there is no way to remove an owner the model invented: nil would simply
let it come back on the next composition. `MeetingVM+Edits.override` is the
other end of the same rule — typing back exactly what was generated drops the
override rather than storing a copy, so a row stops reading as edited.

**The epic has a meeting-level default** (`SummaryEdits.Defaults`, set from the
Action items header) that every row inherits and any row may override or opt out
of. It is the one field with no per-row generated value at all, so its fallback
is the meeting's rather than the model's, and `isEpicInherited` renders it muted
— the same key on twelve rows should read as one answer, not twelve.

**Assignee is two values, not one.** `owner` stays the name that was said; it
travels in the description, the Markdown and the CSV and it never fails.
Reaching a tracker's actual assignee field needs that person's id there, which
lives in `~/Library/Application Support/Piko/people.json` (`Person`,
`PeopleBook`) — app-level, because "Dima is @dmitry on GitHub" is not a property
of one call — and reaches the URL through `{assignee}`, resolved per service
(`LinkTemplate.service`, read off the saved URL so pasted links and preset-built
ones behave alike). An unknown person resolves to empty and takes the parameter
with it: an email in Jira's `assignee` is ignored at best, so `handle(for:)`
falls back to the address only when the service is unknown. The ids are edited
where the name is typed (`PersonEditor` inside the popover) rather than in a
settings screen visited twice a year, and deliberately without a Contacts grant
— Contacts knows an address, not an accountId. `LinkPreset.assigneeServices`
(Jira, GitHub) is the list that gets a field; GitLab and Linear want a numeric
or UUID id that is not visible anywhere in their UI, so a field for them would
be one nobody could fill in.

Jira's epic field is a per-instance custom field id rather than a constant, so
it is an optional setup field on the preset (`{epicfield}`, typically
`customfield_10014`). Left blank, the epic still reaches the description via
`ItemNote` — as it does on every other path, since "which epic" is worth reading
even where it could not be set. The CSV carries it as Jira's own `Epic Link`
column, and there the assignee is the *address* rather than the handle: an
importer resolves people by email or username and never by accountId.

Export is Swift-only: `TaskExporter` (EventKit → Reminders *or* Calendar),
`CalendarFile` / `TaskFile` (`.ics` / `.csv`), `LinkTemplate` (anything with a
prefillable URL) and `MarkdownExport`. Every exported entry carries
`piko://meeting/<id>?t=<seconds>` in its URL field, and `MainView.onOpenURL`
reopens that meeting — the verifiability promise does not stop at the window edge.

EventKit rather than a cloud API is a product decision, not a shortcut: no key,
no OAuth, no network, one system Allow — and it writes into whatever accounts
the Mac already has, **including Google and Exchange calendars**. A Notion or
Jira *API* integration would need a token and would send the meeting off the
machine. The keyless ladder, in order of what it costs the user: Copy/Save
Markdown (nothing) → `.ics` / `.csv` (nothing) → EventKit (one Allow) →
prefilled web compose URLs (a browser tab, `LinkTemplate`) → third-party URL
schemes (the app must be installed) → cloud APIs (key + network — deliberately
out).

A calendar follow-up also inherits from the meeting it came from
(`MeetingContext`): the recording's time window is matched against the user's
events (≥50 % overlap, no all-day, no cancelled), and the winner's hour, length,
conferencing link and participant list are carried onto the new entry — the link
into `location`, where calendars render a Join button, the people into the note.
Nothing is generated: `EKEvent.attendees` is read-only by design, so Piko lists
who to invite and cannot invite for you, and it never mints a call link because
that would need an account. Imported files are skipped — their `started_at` is
the import time, not the call. The match is shown in the sheet with a switch,
never applied silently: a wrong meeting would send everyone to the wrong room.

Several destinations, because no single one fits everybody. **Reminders** and
**Calendar** go through EventKit — updatable by identifier, but only reaching
accounts the Mac is signed into. **Calendar file** (`CalendarFile`) writes an
`.ics`: no permission, no account, read by Google/Outlook/Fantastical/Notion
Calendar, and the only path that can carry `ATTENDEE` lines — an .ics *is* an
invitation, so the guest list survives even though EventKit forbids writing
attendees. Its trade-off is that nothing comes back, so a re-export writes a
second file rather than updating (the stable `UID` at least lets a calendar
recognise a re-import). `WebCalendarLink` is the zero-cost path for people
whose calendar only exists in a browser tab: Google and Outlook (work and
personal live on different hosts, so both are offered) open a prefilled compose
screen where guests can be added in the UI that is allowed to invite them.

Any other service — calendar *or* tracker — is a `LinkTemplate`, a URL with
placeholders in it. One type with a `LinkKind` rather than two near-identical
ones, which is what lets Jira and Google Calendar share a parser, a store, a menu
and a sheet; they differ in the two ways that matter, since an event must sit on a
day and can carry guests while a task needs neither. `LinkParser` reads a pasted
link the service itself produced and works out which parameter is the title,
which are the timestamps (including Google's `A/B` range), which holds the guests
or the deadline, rewriting each as a placeholder; the reading is shown before it
is saved, and hand-written placeholders are taken as-is. Stored in
`~/Library/Application Support/Piko/links.json` (migrated once from
`calendar-links.json`, whose entries had no kind and were all calendars) and
filled in with the same scheduling rules as every other path. A placeholder that
resolves to nothing takes its whole query parameter with it: `duedate=` reads as
a date to some services and as a malformed request to others, and neither is what
"nobody said when" means.

A follow-up's call link and guest list come from the matched event when there
is one, and otherwise from two fields in the sheet — an imported recording has
no event to inherit from, and plenty of calls are in nobody's calendar. What is
typed wins over what was matched, and it is remembered with the meeting.
Reusable sets of people are `GuestGroup`s in
`~/Library/Application Support/Piko/guest-groups.json` — app-level, because "the
ML team" is not a property of one call. Guests only become a real invitation on
the ICS path; EventKit refuses to write attendees, so there they are listed in
the note instead.

**Trackers** are `LinkPreset`s, and they come in two sorts. Trello, Todoist,
Things and OmniFocus need nothing at all, so they are built in exactly the way
Google Calendar is — in the menu from the start, click and their screen opens
(`LinkPreset.builtIn`, i.e. `fields.isEmpty`). Jira, GitHub, GitLab and Linear
cannot be, because a create URL needs the user's own coordinates: Jira the
address plus the numeric project and issue-type ids, GitHub the repository,
GitLab the host and project path, Linear the team. Neither Jira nor GitLab is
assumed to be the hosted one — `FieldValue.baseURL` takes a bare `acme` as a
Cloud site and anything with a dot in it as the address it is, keeping a context
path (`company.com/jira`) intact, and the parser derives the same base from a
pasted link rather than gluing `atlassian.net` onto whatever it found. Those are `LinkPreset.configurable` —
recipes for a saved link rather than destinations, filled in once and then stored
like any pasted one. There is deliberately no "Connect Jira": nothing to connect
to, no token, and nothing leaves the Mac until the person on this side presses
Create. `{owner}` is the name as it was said and goes into the description;
`{assignee}` is that person's id in *this* tracker and is the only thing written
into an assignee field, because a name in a field expecting an account produces a
task assigned to nobody. See "The three fields a transcript cannot answer" above. A built-in whose app is not installed is listed and
switched off rather than hidden ("Piko has no Things support" and "Things is not
on this Mac" are different sentences, and only one is true), and it never reaches
the row menu, which only ever offers what `NSWorkspace` can actually open.

Pasting a link is the main way a tracker gets set up, so `LinkParser` answers with
a **`Reading`**, not an optional: `.ready`, `.incomplete(name:why:next:)`, or
`.unrecognised`. The middle case is the point. Any GitHub, GitLab (self-hosted
included — `/-/` in the path is its signature), Linear or Trello URL a person
already has open carries the coordinates, so those are `.ready` from a repo page,
an issue, a merge request, a board. On-premise Jira is recognised by its host
containing "jira" or by a `/browse/KEY-123` path — that is the link people copy,
and a self-hosted host is otherwise unguessable.

Jira cannot be prefilled from the link people actually have. A `/browse/ABC-1130`
URL names an *existing* issue by key; the create screen is a different endpoint
that identifies the project by numeric `pid` plus `issuetype`, on Cloud as much as
on Server, and no parameter accepts the key instead — which took reading
Atlassian's own tracker to establish rather than guessing. Resolving key → id is
one REST call that needs a token, so it is out by the same rule as everything else
here.

That does not make Jira unusable, and the fourth `Reading` case is why:
**`.copyPaste`**. Any Jira link at all saves a working entry — it opens
`<base>/secure/CreateIssue!default.jspa` and puts the row on the clipboard
(`ItemNote.pasteable`, title first because that is where the cursor lands), so the
cost is one ⌘V instead of a refusal. `LinkTemplate.copiesText` carries that, and
the row is still recorded as sent. The sheet then says how to trade the paste for a
real prefill: open that address, pick project and type, press Next, and the
address you land on has both numbers — paste *that* and the same link upgrades to
full prefill with the `piko://` backlink in the description. `.incomplete` remains
for the cases with nothing usable at all (a GitLab group, a Linear workspace), and
both it and `.copyPaste` carry a `prefill` of whatever *was* readable, so the setup
form opens with the address already in it.

**Task file** (`TaskFile`) is the tracker counterpart of the `.ics`: a CSV that
Jira, Linear, Asana, Trello, ClickUp and Monday all import with no account and no
token, and the only path that moves the whole list in one go rather than one
compose screen per row. Columns are Jira's spelling because Jira is the least
forgiving importer and the rest let you map by hand. Same snapshot trade-off as
the `.ics`, but worse: importers mint their own ids, so a second import duplicates
rather than updates. Multi-line fields (the citation always is) must be quoted —
note that `"\r\n"` is a *single* Swift `Character`, so the structural-character
test is a `Set<Character>`, not a search through a string literal.

The destination menu is grouped by what the row *is* — task first, then event —
because that is the only choice the reader makes, and because somebody who just
saved a `.csv` of their action items is not about to put the same rows in a
calendar. For the same reason the review sheet opens on wherever the last send
went (`TaskExporter.LastUsed`, app-level: it is a property of how someone works,
not of one call) rather than re-asking a settled question every time. An item
with no resolved date cannot become an event and is greyed out there — an event
on a guessed day is worse than no event. Every target is recorded separately in
the overlay (`ExportKey` owns those strings: bare names for EventKit and the
files, so overlays written before links existed keep their badges, then `web:`,
`link:` and `preset:` prefixes), so one row can legitimately be a task *and* an
event *and* a Jira issue. What a link may claim is narrower, though: no
identifier comes back from a compose screen and whether Create was pressed over
there is not ours to know, so those badges say "opened" and re-sending opens the
screen again rather than updating anything. A scheme nothing on the Mac answers
(`things:///add` without Things) is reported rather than swallowed — silence
there is the same bug the send affordance was rebuilt to stop shipping. That
sheet is the one confirm step in the feature, because it writes into another app.

### The model stays loaded

`BackendService` spawns one process per command, writes one JSON line, closes
stdin and reads to EOF. That is right for transcription and rendering — rare,
heavy, and a fresh process is a free guarantee that nothing they allocated
outlives them. It was wrong for chat: closing stdin ends `main.py`'s loop, which
runs `_shutdown()` → `pool.release()` → 4.4 GB of weights freed. Every message
paid the load again, measured at **3.7 s, identical on the second message**,
which is what no reuse at all looks like. Both halves were already built for the
alternative: `main.py` iterates *lines* from stdin and says so, and `pool.py`
exists so "the session outlives the command that created it". Swift was the only
piece closing the pipe.

`ResidentBackend` is one long-lived process for the commands whose cost is the
model (`chat`, `summarize_meeting`, `warmup_llm`, `llm_status`, `release_llm`);
everything else keeps the one-shot contract. A `result` or `error` message is
the request frame — the same terminator EOF used to provide. Requests are
serialized on the actor because an `LLMSession` wraps one decode loop, so two
concurrent generations would interleave inside the model. Measured after:
**3.60 s → 0.88 s → 0.88 s.**

Holding weights is not free, so two things give the memory back. An idle
sweeper releases them after `IDLE_RELEASE_SECONDS` (10 min,
`PIKO_LLM_IDLE_SECONDS`) — holding 4.4 GB for a conversation somebody walked
away from an hour ago is a leak with a good excuse, and the reload costs the
same three seconds it cost the first time. `pool.in_use()` wraps every
generation, and its busy count is what stops that timer freeing weights
mid-summary, since a map-reduce calls `acquire` once and then runs for minutes.
And **Eject** in the sidebar's model card does it now: `release_llm` frees the
weights *and* the process is taken down, because a resident Python that has
merely forgotten its model is still a resident Python.

`mx.clear_cache()` is called on release and **nowhere else** — deliberately not
between requests. MLX's buffer pool *is* the reuse: freed buffers stay around so
the next allocation does not go back to the allocator, and emptying it after
every answer spends the next prompt's first milliseconds to make an idle number
look smaller.

**Why the KV cache is not reused.** A different thing from that pool, and the
obvious next optimisation: a conversation re-sends its whole history every turn,
so turn five re-prefills the system sheet, the open artifact and every earlier
message — thousands of tokens spent proving they have not changed. It was built
and then removed, because on every model Piko ships it cannot pay. Two reasons,
and either alone is enough:

- **The cache cannot be rewound.** Qwen3.5 is hybrid — `make_prompt_cache`
  returns `KVCache` alongside `ArraysCache`, and a recurrent state has no
  position to roll back to. `can_trim_prompt_cache` is False for all four tiers.
- **A rewind is always needed.** The model writes a `<think>` block into the
  cache; the history that comes back next turn carries only the visible answer,
  because that is what the thread shows. So the two diverge a handful of tokens
  before the end — measured at `cached=269, fresh=284, shared=263` — and those
  six have to come off before the shared prefix is usable. `enable_thinking:
  False` is already in `CHAT_TEMPLATE_KWARGS` and this tier opens the block
  anyway.

Reuse without a rewind works only when the next prompt strictly extends the
cache, which a reasoning model's turn never does. Gating it on trimmability made
it correct and inert, and inert code on the only models anyone runs is worse
than none — tokenizing the prompt to discover there is no win costs ~0.3 s on a
1 700-token conversation, which is the whole win. The `reuse_cache` flag stays
on `LLMSession.stream` as the place to hang this if a tier ever ships a
trimmable cache; nothing passes it today.

The card reports what MLX says is resident rather than the benchmark figure —
the number worth showing somebody is the one their machine has. `warmup()` now
polls `llm_status` until loading finishes: `warmup_llm` starts a background load
and returns at once, so reading the status out of its own reply is what made the
workspace claim "model up in 0.3 s" for a model that had not finished loading,
and — before the process was resident — for one that no longer existed.

### Three tiers, all Qwen, nothing above 9B

The ladder is `fast` (2B) / `balanced` (4B, default) / `quality` (9B) and stops
there on purpose (`core/llm/registry.py`). It briefly had a fourth rung and both
candidates for it argued against themselves.

**GPT-OSS 20B** was the only model here from another family and charged for that
everywhere: harmony prompt format instead of Qwen's template, `reasoning_effort`
instead of `enable_thinking` with no "off" at all, and an analysis channel
emitted into the *text* stream. Choosing that tier put this in the chat bubble,
verbatim:

    <|channel|>analysis<|message|>Need to answer: yes, Piko can burn
    subtitles.<|end|><|start|>assistant<|channel|>final<|message|>Yes, …

**Qwen3.6-35B-A3B** replaced it and then failed the only test that matters. On
paper it is the right shape — a mixture of experts, 8 of 256 per token, so ~3B
of 35B does the work, and a third of the dense model's KV cache. In practice it
is 20.4 GB of weights, and on a 36 GB Mac with an ordinary desktop open the
pre-flight check finds ~14 GB available and refuses. A tier that is offered and
then declines to load is worse than one that was never offered.

What this app asks a model to do — pull action items out of transcript chunks,
write a summary, answer a short question about what is on screen — is not where
the last few points of a reasoning benchmark are won. It is where throughput
over nine chunks and fitting in memory are won.

**A summary's peak memory is the prefill window, not the weights.** The map
phase batches chunks through `mlx_lm.batch_generate`, and what costs memory
there is `prefill_batch_size × prefill_step_size` — the number of tokens in one
forward pass, whose activations (a 12288-wide MLP intermediate on the 9B tier,
several live at once) dwarf both the weights and the KV cache. mlx-lm's
defaults put 16 384 tokens in that pass, eight times the window it uses for a
single sequence, and that alone was **7.3 GB on top of the 9B tier's weights**:
12.04 GB peak where the registry claimed 6 GB. `PREFILL_STEP_SIZE = 256`
against `PREFILL_BATCH_SIZE = 8` brings it to 2048 tokens per pass — the same
working set one chat message has — and the whole run to 7.13 GB, for 2.7% more
wall clock. Prefill is bandwidth-bound, so the window is nearly free to
shrink; narrowing the *batch* instead is the bad trade (another 0.5 GB for 8%).

Which is also why `ram_mb` is read from `mx.get_peak_memory()` and never from
RSS: getrusage does not see Metal's buffers, so the figures it gave were 25-35%
low, and `check_memory` was letting a job start that could not fit. A guard
calibrated on a number that cannot see most of the allocation is not a guard.

`commands/reasoning.py` is what keeps thinking out of the thread regardless of
tier. `extract_json` already read past reasoning on its way to an object, so
summaries were never affected; a chat streams raw text and nothing read past
anything. The rule is narrow on purpose: hold back only a reply that *opens*
with a known marker (`<think>`, `<|channel|>analysis`), and only until the
matching end marker arrives — buffering a model that never reasons, while
waiting for an end that never comes, would turn a working answer into a hang.
Deciding per chunk would leak, because tokens do not arrive on marker
boundaries, so the filter answers "not yet" while the text is still shorter than
a marker. While it holds, one `{"type": "chat", "thinking": true}` goes out and
the bubble says so — the thinking is never shown, but an empty bubble for eight
seconds is indistinguishable from a hang.

### Captions skill (`src/piko/skills/captions/`)

Word-level Whisper timestamps flow through:
1. `keyword_detector.py` — emphasis detection via 3 prosody signals (confidence ≥0.92, pause ≥0.3s before, duration ≥1.5× median), 2-of-3 required, EN+RU stop words. No NLP/TF-IDF — importance comes from *how* a word is spoken.
2. `semantic_colors.py` — color words and color-associated objects ("зелёный"→green, fire→orange, рост→green 📈) get painted + emoji, **independent of keyword detection**. EN+RU via stem matching.
3. `styles/` — registry `STYLES` in `__init__.py`. `BaseStyle` owns the generic event generator with three `word_mode`s (static / reveal / highlight with configurable color); line-based styles (mrbeast, hormozi, minimal) only override `decorate_word()`/`word_text()` hooks. karaoke and tiktok override `generate_events()` entirely (built-in animation, word_mode is ignored for them — mirrored in Swift by `supportsWordMode`).

`generate_subtitles()` returns `(SSAFile, emoji_timeline)` — a tuple, not just the file.

**Typography is declared as fractions of the frame, not pixels.** Every style
sets `font_scale` / `margin_v_scale` / `outline_scale` (of frame height) and
`BaseStyle.apply_geometry()` resolves them; the fractions were derived from the
pixel values the styles used to hardcode, so 1080p landscape is unchanged to
the pixel. What changes is everything else: a 4K master no longer gets
1080p-sized lettering, `SIDE_SAFE_AREA` (5 % of width) replaces pysubs2's 10 px
default that ran text to the frame edge, and a taller-than-wide frame is lifted
to `PORTRAIT_SAFE_BOTTOM` (12 % of height) because a style's own bottom margin
lands underneath the TikTok/Reels/Shorts controls. Rotation matters here:
`ffprobe stream=width,height` reports *coded* dimensions and ignores the display
matrix while ffmpeg auto-rotates before the filter chain, so `probe_video()`
swaps them itself — otherwise a portrait iPhone clip stored as 1920×1080 + 90°
gets `PlayRes 1920×1080` over a 1080×1920 frame.

**Cards break at sentences and pauses**, not at a word count
(`group_words_into_cards`). Every limit is checked *before* the word is
appended: checking after is what let one card hold the words on both sides of a
30-second silence and hang on screen for the whole of it. Word count, card
duration and a character budget derived from the actual frame width are the
backstop, not the rule. `plain.py` reuses the same function with reading limits
(42 chars/line, 2 lines, ≤6 s, ≥0.9 s hold) to write the `.srt` and `.vtt`, so
the file handed to YouTube breaks where the picture breaks. Transcript text is
brace-escaped on the way into ASS — an unescaped `{` opens an override block and
swallows the caption.

Fonts are resolved, not requested (`fonts.py`): libass substitutes silently, so
Hormozi asking for Montserrat — which ships with neither macOS nor this repo —
quietly stopped being Hormozi on any clean machine. `pick_font()` takes
preferred-first candidates ending in something macOS always has.

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

- **An undrained ffmpeg stderr deadlocks the render.** `run_ffmpeg()` in `core/media.py` always reads the pipe, whether or not a progress callback was given. ffmpeg writes its banner and continuous stats there; leave it unread and it blocks once the ~64 KB buffer fills, a few minutes into a long encode. `compose_broll` opened the pipe and only drained it when it had a callback — which `_render` never gave it. The same loop keeps the last 24 lines, so a failure reports ffmpeg's own words instead of a bare exit code.
- **Delivery flags are not optional**: `-pix_fmt yuv420p` (a 10-bit HEVC or ProRes source otherwise yields an mp4 that social platforms reject and half the players won't open) and `-movflags +faststart`. Audio is copied only when the container will take it (`MP4_AUDIO_CODECS`) and transcoded to AAC otherwise — a plain `-c:a copy` failed the whole burn on an opus source. `h264_videotoolbox` is used when this Mac's ffmpeg has it, with a resolution-scaled bitrate because VideoToolbox has no CRF; libx264 CRF 18 is the fallback.
- **Swift's `hashValue` is seeded per process** — never put one in a cache key that has to survive a relaunch. `CaptionTranscript.textFingerprint` uses SHA-256 for exactly this reason.
- **SPM + AVKit**: `Package.swift` must keep `.linkedFramework("AVKit")`. SPM autolinks only the `_AVKit_SwiftUI` overlay; without AVKit itself the app crashes at runtime (`getSuperclassMetadata` abort) the moment `VideoPlayer` appears.
- **BackendService project-root discovery** walks up looking for `pyproject.toml` from the bundle path (covers `build/Piko.app` inside the repo) and from `#filePath` (covers bare-executable runs via Xcode/`swift run`, which build into DerivedData/`.build`). Both are dev-machine assumptions by design.
- **Swift concurrency**: `swift build` treats some Swift-6 concurrency issues as warnings; don't mutate captured locals inside the `MainActor.run` closures in VM stream loops.
- **TCC hates ad-hoc signatures**: a permission grant is keyed to the app's designated requirement, which `codesign --sign -` does not provide — every rebuild then looks like a new app and macOS re-asks for the microphone and system audio. `scripts/make-signing-cert.sh` creates a local "Piko Dev" identity once; `make-app.sh` uses it automatically and falls back to ad-hoc with a warning. Reset a grant while testing with `tccutil reset Microphone dev.bogdanminko.piko` (and `AudioCapture` / `SystemAudioCaptureRequests` for system audio, `Reminders` for the action-item export).
- **Hardened Runtime fails silently, TCC does not**: `make-app.sh` signs with `--options runtime`, and under it a protected resource needs its entitlement even though the app is *not* sandboxed. Without one there is no prompt, no error, and the app never appears in the Privacy pane at all — the request dies before TCC sees it. That is exactly what an unentitled Calendar export looked like. `com.apple.security.device.audio-input` covers the microphone, `com.apple.security.personal-information.calendars` covers Calendar; Reminders needs no entitlement of its own. Symptom to recognise: "Piko isn't in the list" ≠ a denied grant, and `tccutil reset` will not fix it.
- **Deployment target is macOS 14.4** (`Package.swift` + `LSMinimumSystemVersion`), set by Core Audio process taps — the API lands in 14.2 but its permission prompt only behaves from 14.4.
- After changing UI state flow, remember `MainView` re-renders on changes of `selectedStyle`, `wordMode`, `highlightColorHex` via `.onChange` → `reRender()` (only when state is `.done`).
- Renaming/moving: project was renamed creit→piko in-place; if the venv or Swift `.build` cache misbehaves after a rename, delete `.venv`/`.build` and rebuild.
