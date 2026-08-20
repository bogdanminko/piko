# Action Items — design

*How a generated meeting summary becomes something the user can edit, own, and
push into the tools they already live in. Feature design + implementation plan;
visual design is iterated separately as HTML mockups.*

Depends on Meeting Summary (`summarize_meeting`, `summary.json`). Extends
PRODUCT.md's Meeting Summary definition of done — "an editable result",
"action items (with assignee and due date when stated)" — into a shipped shape.

## The problem

A summary item today is `text / start / owner? / due?`
(`Piko/Models/MeetingSummary.swift`), rendered read-only:

- **No state.** The checkbox in `MeetingSummaryCards.swift` is a drawn
  rectangle. Nothing can be ticked, corrected or removed, and a re-run with
  `force` rewrites `summary.json` wholesale.
- **No real date.** `due` is the phrase as spoken ("by Friday", "к пятнице").
  Neither a reminder nor a calendar event can be created from that.
- **No way out.** A task that only exists inside Piko is one more list nobody
  reads. The user already lives in Reminders, Calendar and their notes app.

## Shape of the solution

Two decisions carry the whole feature.

### 1. Edits are an overlay, not a mutation

`summary.json` stays strictly derived — regenerable at any time, like the
transcription cache behind the captions skill. Everything a human does goes
into a separate file that generation never touches:

```
<recording>/summary.json        # model output. Freely overwritten.
<recording>/summary.edits.json  # human output. Never overwritten.
```

The view renders the *composition* of the two. This buys, for free:

- "Restore generated" on any field, and on the whole summary — the original is
  still there;
- an `edited` marker per item, so we never present a user's wording as
  something the model claimed;
- re-summarization stops being a destructive button.

The overlay is also where task state lives, so there is no separate
`tasks.json`: one mechanism covers edits, done-state and export records.

### 2. Every exported item carries a `piko://` backlink

PRODUCT.md's differentiator is verifiability, and today it stops at the app
boundary. A reminder created from an action item gets
`piko://meeting/<recording-id>?t=612.4` in its URL field: one click reopens
Piko at the second the task was agreed on. That is something no cloud meeting
tool can do, because they have no local recording to jump into — and it costs a
URL scheme plus a handler.

## Data model

`summary.edits.json`, owned by Swift (`MeetingLibrary` already owns on-disk
meeting state; the backend is a short-lived per-command process and cannot hold
any).

```
version
fields:  { brief?, summary?, topics?[] }        # whole-field overrides
items:   [ Edit ]
Edit:
  id            UUID, minted on first edit or on manual creation
  anchor        { list, start, fingerprint } | null   # null for manual items
  list          decisions | action_items | open_questions   # may differ from anchor.list
  text?, owner?, dueRaw?, dueDate?, dueHasTime?            # overrides
  deleted       bool
  done, doneAt?
  start         # manual items only; taken from the playhead
  origin        generated | manual | orphaned
  exports       [ { target, externalID, exportedAt } ]
```

### Identity and re-generation

`Item.id` is `"\(start)-\(text)"` today: it breaks on the first text edit, and
it does not survive re-generation — a second pass cites a neighbouring line and
`start` shifts by a few seconds. So the overlay keeps its own UUIDs and
re-attaches them by anchor: same list, `|Δstart| ≤ 15s`, text similarity above
a threshold.

Unmatched edits are **never dropped**. They become `origin: orphaned` and stay
visible as manual items. Showing one stale row is recoverable; deleting text a
person typed is not.

### What is not editable

`start` on a generated item. A timecode is a citation, not a field. Moving an
item to a different moment is an explicit action (drop it at the playhead),
which marks the item `edited`.

Everything else is editable: brief, the long summary, topics (add / rename /
remove), item text, owner, due, deletion, manual insertion, and moving an item
between the three lists — small models routinely file a proposal as a decision,
and correcting that must not require re-running the model.

## Due dates

`due` stays the phrase as spoken; a resolved date is added beside it.

Resolution runs in the backend, where the LLM session already exists, anchored
on the recording's own date (`meta.json:started_at`, passed in as
`meeting_date`). One cheap extra pass over the ≤10 action items, strict schema,
`null` when unsure — the same rule that keeps timecodes honest in
`skills/meeting/summary.py`: *a date is resolved or absent, never guessed*.

The raw phrase stays on screen as the source; the ISO date is presented as an
editable suggestion. `summary.json` gains `due_date` (`YYYY-MM-DD`) and
`due_time` (`HH:MM`, optional) next to `due`; `BackendMessage.swift` and
`MeetingSummary.Item` follow.

**Owner, cheaply:** the transcript segment at `start` knows which side spoke it.
An action item spoken by the `me` side in the first person is the user's own —
enough to pre-fill "You" without a model call.

## Destinations

**Reminders is the default.** An action item is a task, not an event. `EKReminder`
takes `title`, `dueDateComponents`, `notes` (the cited line + meeting title) and
`url` (the backlink). A "Piko" list is created once. iCloud then puts the task
on the user's phone with no sync code and no account on our side — which is
exactly the zero-setup, local-by-default promise.

**Calendar is an explicit choice, not the default.** Ten "events" out of one
call is calendar spam. Two cases justify it: the item *is* a meeting ("let's
sync Thursday"), or the user asks to **Block time** — a timebox of N minutes on
the due date. Offered only when a date resolved.

It also answers the fair objection *"who even opens Reminders?"* — Reminders
only works for people living in the Apple ecosystem, while EventKit's calendar
side writes into Google and Exchange accounts configured on the Mac, which is
where most work calendars actually are. The destination is an adapter; what
makes the feature is the citation and the backlink travelling with the item.
A shipped item lands all-day on its resolved date unless a time was stated,
because nobody said an hour and inventing one is the same failure as inventing
a timecode.

**Notes: snapshot plus backlink, no sync.** The unit here is the meeting, not the
item. Apple Notes has no public API and no embed; an AppleScript bridge is
fragile and needs an Automation grant. So Piko stays the source of truth and
hands out Markdown with `piko://` links per timecode:

- Copy as Markdown / Save as `.md` (this also fills the `Export Markdown`
  placeholder in `MeetingSummaryView.swift`);
- **Share → Notes** via `NSSharingServicePicker` — the system sheet, zero
  permissions, no AppleScript, and Mail/Messages come along for free.

Exports carry the *composition*, i.e. the user's wording. The common flow is
"fix the phrasing so it reads outside the call, then send".

## Interaction rules

- Ticking, editing and deleting write to the overlay immediately; no save button.
- **Single-item export writes immediately** with an undo affordance. **Bulk
  export opens one review sheet** — checkboxes, resolved dates, target list —
  because writing into someone's Reminders is outward-facing and not trivially
  reversible. One sheet, not a wizard.
- An exported row shows where it went; re-export updates the existing reminder
  by `externalID` instead of creating a duplicate.
- Completion read-back (closed in Reminders → ticked in Piko) is read-only and
  runs only when the grant already exists. Without it the checkbox would lie.

## Implementation plan

**Backend** (small, contained):
1. `skills/meeting/summary.py` — `due_date` / `due_time` in the schema, a
   resolution pass anchored on `meeting_date`, `null` over guesses.
2. `commands/meeting.py` — accept `meeting_date` in `summarize_meeting`.
3. `tests/test_protocol.py` keeps the emit ↔ `BackendMessage` contract honest;
   extend the summary fixtures.

**Swift**:
4. `Models/SummaryEdits.swift` — the overlay type + composition
   (`MeetingSummary` + edits → the view model the cards render).
5. `Services/Recording/MeetingLibrary.swift` — load/save
   `summary.edits.json`, atomic writes, anchor re-attachment on re-generation.
6. `ViewModels/MeetingVM.swift` — expose the composed summary, mutation methods
   (`toggleDone`, `edit`, `delete`, `addManualItem(at:)`, `restore`), and stop
   assigning `summary` straight from the backend message.
7. `Services/TaskExporter.swift` — EventKit: permission, "Piko" list, create /
   update by `externalID`, optional completion read-back.
8. `Services/MarkdownExport.swift` — composition → Markdown with `piko://`
   links; `NSSharingServicePicker` hook.
9. `PikoApp.swift` + `scripts/make-app.sh` — `CFBundleURLTypes` for `piko://`,
   `onOpenURL` → select recording, seek player.
10. Views: editable cards, review sheet, export badges (visual design separate).

**Order:** 4→6 first (editing works, nothing leaves the app), then 1–3 (real
dates), then 7 (Reminders), then 8–9 (Markdown + backlink).

## Gotchas

- **TCC and the signing identity.** `NSRemindersFullAccessUsageDescription` (and
  `NSCalendarsFullAccessUsageDescription` later) go into the Info.plist that
  `make-app.sh` writes. The same trap as the microphone applies: a grant is
  keyed to the designated requirement, so without the "Piko Dev" identity every
  rebuild re-asks. Reset while testing with
  `tccutil reset Reminders dev.bogdanminko.piko`.
- **Merge on re-summarize** is the likeliest source of bugs. Rule to hold:
  `force` never deletes an edit; worst case it orphans one.
- **Resolved dates can be wrong.** Mitigated by null-over-guess and by keeping
  the spoken phrase visible next to the date.
- **`piko://` is an entry point.** The handler only selects a local recording by
  id and seeks; it must not accept paths or run anything.

## Staging

- **v1 — shipped:** the overlay (`summary.edits.json`) with anchor re-attachment,
  real checkboxes, inline text editing, delete and hand-added items, due-date
  resolution in the backend, `piko://` in and out, Reminders export with the
  backlink and update-by-identifier, Calendar export for dated items (all-day
  unless a time was stated), `.ics` export with the guest list, an "Open in
  Google Calendar" link, Markdown save / copy.

  Three things landed differently from the sketch above, all deliberately:
  **(a)** an added item has no timecode, because the summary screen has no
  player to take a playhead from yet — it is marked `manual` rather than given
  a fake position; **(b)** a single row exports through the same review sheet
  (pre-selected) instead of writing immediately with an undo, so there is one
  path into Reminders rather than two and nothing to undo; **(c)** the overlay
  carries brief/summary/topics overrides, but only item-level editing has a UI —
  the fields are reachable the moment a design for them exists.
- **v1.1:** Block time (a timebox rather than an all-day entry), completion
  read-back, a cross-meeting
  Tasks section (a folder scan over the overlays — no new model), per-meeting
  free-text `notes.md`, an audio player so a timecode (and a hand-added item)
  has somewhere to seek.
- **v2:** "Create follow-up" surfaced as a *skill* in Library rather than as a
  chat — picking a recording and being offered what can be made from it is
  ARCHITECTURE's `Drop anything → applicable skills → result`, and a slash
  command that assembles a guest list is a worse picker, not a better one.
  Things/Todoist URL schemes, Obsidian vault folder, Notes via
  AppleScript, owner → contact/email, follow-up invitations. Cloud APIs
  (Notion, Linear, Google Tasks) stay out: they need a key and they send the
  meeting off the machine.
