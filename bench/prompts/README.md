# Piko Prompt Benchmark

The system prompts themselves, measured on the three tiers the product ships
(`fast` 2B / `balanced` 4B / `quality` 9B, all Qwen3.5 at 4-bit). Candidates are
scored on what the summary is worth to a reader and on what it costs to produce,
behind hard gates for parsing, citations and language.

The loop that produces these rounds is a skill: `.claude/skills/prompt-lab/`.
The score is defined in `references/rubric.md` and executed by `score.py`.

```
PPS = 60 x quality + 15 x reliability + 15 x efficiency + 10 x simplicity
headline = 0.25 x fast + 0.50 x balanced + 0.25 x quality-tier
```

`quality` is blind judgement on four axes (faithfulness, coverage,
bullshit-free, actionability); the other three are computed from the runs.
Three gates sit outside the sum — parses ≥95%, **zero** invented citations,
100% language compliance — because a weighted score offers an exchange rate
between "invented a citation" and "wrote nicely", and there is no rate at which
that trade is acceptable here.

## Round 1 — nothing shipped, four defects found

`--tag r1`, 102 runs, greedy, seed 0. 60 extract + 24 reduce + 18 due.

### extract — the shipped prompt stands

| variant | headline | quality (bal) | reliability | efficiency | chars |
|---|---:|---:|---:|---:|---:|
| `v2-minimal` | **75.2** | 0.72 | 0.91 | 0.91 | 561 |
| `v0-shipped` | 74.0 | 0.74 | 0.98 | 0.83 | 858 |
| `v1-contrastive` | 73.6 | 0.73 | 0.90 | 1.00 | 1054 |
| `v3-procedure` | 70.2 | 0.71 | 0.79 | 0.79 | 1091 |

Judged quality on the default tier is a four-way tie inside 0.03. `v2-minimal`
leads by 1.2 points and every one of them comes from being 35% shorter and
cheaper to run, not from being better at the task. By this bench's own stop rule
that is noise, so **round 1 ships nothing for `extract`** — and the useful
finding is that a prompt a third shorter loses nothing measurable, which is a
round-2 candidate rather than a result.

### reduce — one variant survives 2B, and that is not a score difference

| variant | headline | quality (bal) | reliability | efficiency | chars |
|---|---:|---:|---:|---:|---:|
| `v1-contrastive` | **80.3** | 0.84 | 0.93 | 1.00 | 999 |
| `v0-shipped` | unfit (fast) | 0.84 | 0.95 | 0.93 | 842 |
| `v2-minimal` | unfit (fast) | 0.79 | 0.95 | 0.94 | 515 |
| `v3-proportion` | unfit (fast) | **0.93** | 0.97 | 0.99 | 931 |

`v3-proportion` writes the best summary anyone wrote here and cannot ship:
it fails the parse gate on 2B. See defect 1.

### due — no judgement needed, and no winner

| variant | headline | accuracy (bal) | accuracy (fast) | accuracy (9B) | chars |
|---|---:|---:|---:|---:|---:|
| `v2-minimal` | 79.5 ⚠ | 0.90 | 0.45 | 0.80 | 411 |
| `v0-shipped` | 75.9 ⚠ | 0.90 | 0.50 | 0.75 | 640 |
| `v1-worked` | 75.0 | 0.85 | 0.55 | 0.75 | 871 |

⚠ tier-fragile: more than 20 points below its own headline on 2B. `v1-worked` is
the only variant that is not, and it buys that by being the longest and slightly
worse on the default tier. Nothing here is a clear improvement.

## What round 1 actually found

**1. On 2B, a meeting summary can be lost entirely.** Three of four reduce
prompts — the shipped one included — fell into a repetition loop on
`en-release-call` and ran to the full 4096-token cap, emitting the same action
item several hundred times and an object that does not parse. Not a worse
summary: no summary. The trigger is the input pattern, not the wording — that
case is the one whose partials carry the same item twice, and every prompt that
failed, failed on it. `v1-contrastive` was the only escape, on one run, which is
a signal to confirm in round 2 rather than a fix.

Production softens this: `generate_json` retries once at temperature 0.4, so a
real user sees a slow summary rather than a failed one, some of the time. It
does not remove it.

**2. No prompt merges near-duplicates, at any tier.** All nine parseable reduce
outputs kept both `[7] Ship on Thursday instead of Friday` and `[9] Ship
Thursday, with the release branch cut the evening before` as separate decisions,
and all nine kept the restated fact `[4] the billing page misalignment is
cosmetic` in the decisions list. Merging duplicates is the reduce step's first
rule and its main reason to exist.

`_dedupe` in `summary.py` will not save this: it normalises whitespace and case
and compares whole strings, so two differently-worded statements of one decision
are two decisions on screen. Only the pair of identical `Write the release
notes` items is caught.

**3. Speaker labels reach `owner` on every prompt, worst on the largest tier.**
17 of 60 extract runs wrote `Participants` or `You` into an owner field, despite
a rule forbidding exactly that in three of the four prompts. The shipped prompt
on 9B did it on all four action items of `en-release-call`. `_resolve` strips
them, so the visible symptom is not a wrong owner — it is that a task whose
owner was actually named comes out ownerless, and nothing on screen says why.

The same leak reaches reader-facing prose, where nothing strips it: one German
output reads *"Der technische Teil der Präsentation wird von den Participants
gehalten"*.

**4. German is the weakest language, and it is not the language rule that
fails.** Every output was in German; the gate passed. But `de-short-call` is the
worst case in the round on every judged axis: five of twelve returned an empty
`action_items` for a call whose whole point was "ask Kerstin today", four
invented a settled decision about the price list where the transcript says
nobody knows, and one moved the meeting to *Donnerstag*. Russian, with a longer
and noisier transcript, did far better. Short transcripts appear to be harder
than noisy ones.

Two smaller ones:

- **9B invents deadlines that 4B does not.** `next sprint` / `в следующем
  спринте` resolved to a real date on the `quality` tier for two variants; on
  `balanced` no variant did. The largest model is the only one that fabricates
  here.
- **Items come back as bare strings.** Several outputs emitted
  `open_questions: ["What breaks at quarter end?"]` with no object and no `ref`.
  `_resolve` drops them silently, so the metric that matters is not "is the
  citation wrong" but "did the item survive to the screen at all". That is why
  `refs_missing` is scored separately from `refs_bad`.

And one thing that works: **the anti-padding rule holds**. On
`en-nothing-decided`, all twelve outputs left `decisions` and `action_items`
empty. Whatever else these prompts do, none of them invents a decision to fill a
card.

## Known defects in the eval

- `due` case `end of day` expects `time: null` and every variant answers
  `23:59`, which is a defensible reading of the phrase rather than an invention.
  It costs every variant the same 0.1 of accuracy on both `due` cases, so the
  ranking is unaffected — but the absolute numbers are one item low. Fix in
  round 2 by accepting `23:59` or dropping the item.
- `v1-worked`'s examples share phrase families with the `due` cases (a weekday,
  a relative offset, an unresolvable condition). Different anchor date and
  different phrases, so no answer is leaked, but the *form* is taught. Worth
  remembering when reading its score.
- Every case here was written by the same model that judges the outputs. The
  holdout — a real recording, handed over deliberately — is the check on that,
  and it has not been run yet.

## The data

11 synthetic cases with answer keys, in `cases/`:

| target | cases | what each is for |
|---|---|---|
| extract | `en-release-call` | the ordinary case: a date settled by rejecting another, three tasks with one named person, options nobody chose |
| | `en-nothing-decided` | a discovery call that settles nothing — the honest answer is two empty lists |
| | `ru-standup-notes` | Russian ASR run-ons, plus a typed note that contradicts the transcript's spelling of a name |
| | `en-unowned-tasks` | one named person, and tasks that must not all be given to them |
| | `de-short-call` | a third language, and a short one |
| reduce | `en-release-call` | partials carrying the same decision twice with two refs, and one restated fact |
| | `ru-thin` | an eight-line meeting against a 2000-character ceiling, plus an untimed note |
| due | `en-mixed`, `ru-mixed` | ten spoken deadlines each, half of them unresolvable |

Each key names what must be found, and the **traps** — a thing that must not
appear in a given field, because the transcript made it tempting.

## Reproduce

```bash
uv run python bench/prompts/run.py   --target extract --tag r1     # ~15 min, all tiers
uv run python bench/prompts/score.py --tag r1 --target extract     # deterministic half
# judge results/r1/judge/extract/*.md blind, write scores.extract.json, then:
uv run python bench/prompts/score.py --tag r1 --target extract --markdown
```

Runs in the app's own venv — the harness adds no dependencies and imports the
shipping code (`_chunk_message`, `_notes_message`, the schemas) rather than a
copy of it, so what is measured is what runs.
