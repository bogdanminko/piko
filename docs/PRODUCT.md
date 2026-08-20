# Piko — Product

**Artifacts that finish the job — open source, and local to your Mac.**

> An artifact you can ask for is half a result. Piko carries it the rest of the
> way: recording to transcript to summary to action items that land in the
> calendar and the tracker, with no plumbing in between.

Which model does the work is an implementation detail, and swappable. What is
not negotiable is where it runs (this Mac) and how far it goes (all the way).

## Who it's for

*Working hypothesis — validate with the first real users.*

People who work on a Mac and accumulate recordings they never get value from:
remote workers drowning in calls, creators clipping long footage, students with
lectures. They are not AI enthusiasts — they will not install Ollama, pick
quantizations, or tune prompts. What makes them choose Piko: it works out of
the box, costs no subscription, and nothing leaves their machine.

## Why Piko and not the alternatives

- **Cloud meeting tools (Granola, Fireflies, …)** — recordings and transcripts
  never leave the Mac; no subscription; works offline. For anyone whose calls
  contain client or company material, "local" is a requirement, not a feature.
- **MacWhisper and transcription apps** — Piko's unit is not a transcript but a
  finished result: a styled video, a summary you can *verify*. Every claim in a
  summary links back to the moment in the recording it came from; one click
  jumps there. Verifiability is the differentiator, and it matters more than
  polished prose.
- **LM Studio and chat UIs** — no chat, no prompting, no model babysitting.
  Drop a file, get a result. Piko is not a replacement for LM Studio and does
  not compete with it.

## Product principles

1. **The unit is a result, not a message** — a subtitled video, a summary, a
   list of action items. Never an open-ended conversation.
2. **Verifiable by construction** — whenever possible, every generated claim
   links to the source fragment that supports it.
3. **Zero setup** — one app. Models download in-app as three tiers (**fast /
   balanced / quality**) sized against the machine's RAM; the biggest default
   tier must run comfortably on a 16 GB M-series Mac. No external servers, no
   second app to install. Power users get a custom-model escape hatch in
   settings, not a longer picker.
4. **Local by default** — all processing on-device.

## Meeting Summary — the furthest along, and the current focus

Audio/Video → Transcription → Structured Summary → Editable Result → Export.

Recording, speaker attribution, summarization and export all work today. What
keeps it from being called finished is the bar below, not missing pieces.

**Definition of done** — the user drops an hour-long call recording and, fully
locally on a 16 GB M-series Mac without swapping, gets:

- a transcript with timecodes;
- a brief summary, main topics, decisions, action items (with assignee and due
  date when stated), open questions, key quotes;
- every item linked to its timecode — one click jumps to that moment;
- an editable result and Markdown export.

Until every line above works end-to-end, Meeting Summary is not done.

## Captions

Video → Transcription → Timed Captions → Styled Video. The first skill built,
and still the proof that the shape generalises: a different input, a different
result, the same path from request to finished thing.

*Technical shape of artifacts, skills, and the model runtime lives in
[ARCHITECTURE.md](ARCHITECTURE.md) — direction, not commitment.*
