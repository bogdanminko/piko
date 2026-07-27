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

Each command = one short-lived Python process. Swift writes one JSON command to stdin; Python emits newline-delimited JSON messages (`progress` / `result` / `error` / `models`) to stdout. **stdout is protocol-only** — mlx-whisper's prints are redirected to stderr in `core/transcriber.py`; never `print()` to stdout in the backend. Message schema lives in `src/piko/commands/` (emit sites) and `Piko/Models/BackendMessage.swift` (one big optional-field struct; keep the two in sync + CodingKeys for snake_case).

Commands: `process` (full pipeline, CLI convenience), `transcribe` (slow, cached), `render` (fast, repeatable), `finalize_recording`, `import_recording`, `transcribe_meeting`, `summarize_meeting`, `style_previews`, `list_models`, `download_model`, `check_model`.

### Two-phase pipeline + caching

Transcription is decoupled from rendering so style/animation changes never re-run Whisper:

1. `transcribe` → cached JSON in `~/Library/Caches/piko/transcriptions/<sha1(path+mtime+model+lang)>.json`; returns `transcription_path`.
2. `render` → takes `transcription_path` + style + word_mode + highlight_color, generates .ass, burns with ffmpeg (~sub-second for short clips).

The Swift `VideoProcessorVM` additionally keeps a per-session render cache keyed by output path (which encodes style+mode+color), so switching back to an already-rendered combination swaps files instantly without calling the backend. The app never writes next to the user's video: renders and .ass files go to `~/Library/Caches/piko/renders/`, and the user exports explicitly via the Save Video… / Save Subtitles… buttons (NSSavePanel + copy). The sidebar's "Clear Cache" button wipes the whole `~/Library/Caches/piko` directory (style previews regenerate on the next `style_previews` call). The `piko_output/` default in `commands/render.py` only applies to CLI use without an explicit `output_path`.

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

**Permissions** live in `RecordingPermissions`. Microphone has a real API;
system audio has none — a tap without the grant "succeeds" and returns silence
forever, so the check is empirical: start a tap, play a short sound, see if the
tap heard it. That same first tap creation is what raises the macOS dialog.

### Library: one session history over both verticals

The Library screen (`LibraryView` + `LibraryRow`, model in `Models/LibraryItem.swift`)
is a *derived* view, never a third store: it joins the two histories that already
exist — meetings (folders under `Application Support/Piko/Recordings`, enumerated
by `MeetingLibrary.list()`) and captions runs (`history.json`, `HistoryStore`) —
so a recording is history the moment it is saved, with nothing to keep in sync.
A row's stage (Recorded → Transcribed → Summarized, or Captioned) is read from the
files on disk on every scan (`MeetingLibrary.hasTranscript/hasSummary`) rather than
stored, so a rerun or a folder deleted from Finder can't leave a stale badge.
Rows group by calendar day, open on their own screen (meeting → Meeting Summary
with that recording selected, captions → Captions), and expose Rename, Reveal in
Finder, Export Markdown (the *composed* summary, edits included) and delete.
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
- **TCC hates ad-hoc signatures**: a permission grant is keyed to the app's designated requirement, which `codesign --sign -` does not provide — every rebuild then looks like a new app and macOS re-asks for the microphone and system audio. `scripts/make-signing-cert.sh` creates a local "Piko Dev" identity once; `make-app.sh` uses it automatically and falls back to ad-hoc with a warning. Reset a grant while testing with `tccutil reset Microphone dev.bogdanminko.piko` (and `AudioCapture` / `SystemAudioCaptureRequests` for system audio, `Reminders` for the action-item export).
- **Hardened Runtime fails silently, TCC does not**: `make-app.sh` signs with `--options runtime`, and under it a protected resource needs its entitlement even though the app is *not* sandboxed. Without one there is no prompt, no error, and the app never appears in the Privacy pane at all — the request dies before TCC sees it. That is exactly what an unentitled Calendar export looked like. `com.apple.security.device.audio-input` covers the microphone, `com.apple.security.personal-information.calendars` covers Calendar; Reminders needs no entitlement of its own. Symptom to recognise: "Piko isn't in the list" ≠ a denied grant, and `tccutil reset` will not fix it.
- **Deployment target is macOS 14.4** (`Package.swift` + `LSMinimumSystemVersion`), set by Core Audio process taps — the API lands in 14.2 but its permission prompt only behaves from 14.4.
- After changing UI state flow, remember `MainView` re-renders on changes of `selectedStyle`, `wordMode`, `highlightColorHex` via `.onChange` → `reRender()` (only when state is `.done`).
- Renaming/moving: project was renamed creit→piko in-place; if the venv or Swift `.build` cache misbehaves after a rename, delete `.venv`/`.build` and rebuild.
