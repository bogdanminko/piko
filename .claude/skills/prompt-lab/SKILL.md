---
name: prompt-lab
description: Write and iteratively improve Piko's system prompts by measuring them against the three shipped model tiers. Use when editing EXTRACT_SYSTEM, REDUCE_SYSTEM, SHORTEN_SYSTEM, DUE_SYSTEM or CAPABILITIES; when a summary comes back padded, hallucinated, in the wrong language, missing citations or slow; or when asked to compare, score or optimise prompts. Runs bench/prompts across 2B/4B/9B, judges the outputs blind, and publishes a leaderboard.
---

# Prompt lab

A prompt in this repo is not a piece of writing, it is a component with a
measurable contract, and it runs on a 2B model on somebody's laptop. This skill
is the loop that changes one and knows whether it got better.

**The rule that decides most calls here: the best prompt is the shortest one
that still passes.** Length is not thoroughness. Every extra clause is more
prompt for a 2B model to lose the thread in, more tokens per chunk across a
sixteen-chunk meeting, and one more thing to contradict. When two variants score
within a couple of points, the shorter one wins.

## What exists

| | |
|---|---|
| Harness | `bench/prompts/` — `run.py`, `score.py`, `tasks.py`, `metrics.py` |
| Targets | `extract`, `reduce`, `due` (registry in `tasks.py`; `source` names the shipped constant) |
| Cases | `bench/prompts/cases/<target>/*.json` — synthetic, each with an answer key and traps |
| Variants | `bench/prompts/variants/<target>/*.txt` — `v0-shipped.txt` is always the live prompt |
| Results | `bench/prompts/results/<tag>/` — `raw.jsonl`, `judge/`, `scores.*.json` |
| Leaderboard | `bench/prompts/README.md` |
| Score | `references/rubric.md` — read it before judging anything |
| Techniques | `references/techniques.md` — read it before writing a candidate |

Runs in the app's own venv; the harness adds no dependencies.

## One round

### 1. Pick the target and read the last round

```bash
cat bench/prompts/README.md
uv run python bench/prompts/score.py --tag <last-tag> --target <target>
```

The leaderboard is the state of this loop. Do not start a round without reading
what the previous one concluded, or you will re-propose a candidate that already
lost.

### 2. Diagnose before writing

Read the *failing traces*, not the scores. For every run where the current best
lost points, open its output in `results/<tag>/judge/<target>/<case>.md` and say
in one sentence what the prompt did wrong — not what it should say instead. This
is the reflective half of the loop and skipping it produces candidates that vary
the wording of a rule that was never the problem.

Diagnoses that lead somewhere look like: *"on the meeting where nothing was
settled, 2B invented two decisions — the rule permitting an empty list is the
last line of eight and it is a permission, not an instruction."* Diagnoses that
do not: *"the output was low quality."*

### 3. Write at most three candidates, each changing one thing

Read `references/techniques.md` first. Then:

- **One hypothesis per variant, and the filename is the hypothesis.**
  `v4-empty-first.txt`, not `v4-improved.txt`. A variant that changes three
  things teaches you nothing when it wins.
- **Section-local edits.** Change a rule, a definition block, or the ordering —
  not the whole prompt. The baseline is a prompt that already works; a rewrite
  throws away everything it got right along with the bug.
- **Always carry `v0-shipped.txt` forward** into the run. Without the live
  prompt in the same run, a leaderboard measures candidates against each other
  and cannot tell you whether to ship any of them.
- **Placeholders are a contract.** `tasks.py` lists what each target may use
  (`{language}`, `{notes_rules}`, `{brief}`, `{summary}`, `{topics}`). Using one
  that is not listed fails at format time, which is correct. Using fewer is
  allowed — dropping `{notes_rules}` is itself a testable hypothesis.
- **A candidate longer than the baseline needs a reason stated up front.** It
  will be paying the simplicity term and the efficiency term on every chunk of
  every meeting forever.

Regenerate `v0-shipped.txt` if the source has moved since the last round:

```bash
uv run python - <<'PY'
from pathlib import Path
from piko.skills.meeting.summary import EXTRACT_SYSTEM, REDUCE_SYSTEM, DUE_SYSTEM
root = Path("bench/prompts/variants")
for name, text in (("extract", EXTRACT_SYSTEM), ("reduce", REDUCE_SYSTEM), ("due", DUE_SYSTEM)):
    (root / name / "v0-shipped.txt").write_text(text + "\n")
PY
```

### 4. Run

```bash
uv run python bench/prompts/run.py --target <target> --tag r<n>
```

One subprocess per tier, one model load each, greedy with a fixed seed. A full
target is roughly 15–25 minutes on an M4 Max; say so before starting it rather
than leaving the machine apparently wedged.

Narrow with `--variants a,b` / `--cases id,id` / `--tiers balanced` while
iterating on a single failure. A narrowed run still writes to the same `raw.jsonl`,
so give exploratory work its own tag (`--tag probe-empty`) and keep round tags
clean.

### 5. Read the deterministic half before judging

```bash
uv run python bench/prompts/score.py --tag r<n> --target <target>
```

Everything except `quality` is computed from the runs alone. A variant that
failed a gate — did not parse, cited a line nobody said, answered in the wrong
language — is already out, and judging it is wasted effort. Say which candidates
died here and why before opening a single output.

### 6. Judge blind

Read `references/rubric.md` in full. Then, for each case:

1. Open `results/<tag>/judge/<target>/<case>.md`. It holds the transcript, the
   answer key, and every variant's output for that case under opaque ids, in a
   shuffled order.
2. Score all four axes for every sample, comparing them against each other
   inside the case. Write into `results/<tag>/judge/scores.<target>.json`.
3. **Do not open `key.json` until every score is written.** It maps sample ids
   to variants. Knowing which output is the candidate you wrote an hour ago is
   exactly the bias this arrangement exists to remove, and there is no way to
   un-know it once read.

`due` is not judged: dates match or they do not, and `score.py` uses that
accuracy directly.

### 7. Score, publish, decide

```bash
uv run python bench/prompts/score.py --tag r<n> --target <target> --markdown
```

Update `bench/prompts/README.md` with the table and — more importantly — with
what the round *learned*. A leaderboard nobody can read the reasoning off is a
scoreboard for a game whose rules were forgotten.

Then one of:

- **Ship it.** The winner beats `v0-shipped` on headline PPS, is not
  tier-fragile, and fails no gate. Edit the constant in the source named by
  `tasks.py`'s `source` field, keep the module docstring honest, and run
  `uv run pytest -q` — `tests/test_summary.py` asserts things about these
  prompts.
- **Another round.** The winner is a candidate that also opened a new failure.
  Carry it forward as the new baseline alongside `v0-shipped`.
- **Stop.** Two consecutive rounds where nothing beats `v0-shipped` by more than
  ~2 points means this prompt is done. Say so and stop, rather than generating
  variants until one wins by noise.

## Holdout

`cases/holdout/` is for the user's own recordings and is gitignored. It is used
**once, on the winner, at the end of a round** — never inside the loop. Every
case in `cases/` was written by the same model that judges the outputs, and a
prompt tuned to convergence on those is tuned to that model's idea of a meeting.

Getting a holdout case is asking the user for one specific file, per the rule at
the top of `CLAUDE.md`. Never enumerate `~/Library/Application Support/Piko/` to
find something to test against.

## Adding a target

`CAPABILITIES` in `src/piko/commands/chat.py` is not registered yet. To add it:
an entry in `TARGETS`, a `_build_chat` that assembles the sheet the way
`_conversation()` does, cases under `cases/chat/` whose keys say which features
must be refused, and a `measure` branch. Its rubric is different — there is no
schema and no citation, and the axes that matter are *refuses what does not
exist*, *short*, and *answers in the user's language*.

## What not to do

- **Do not tune on one case.** A rule added to fix `en-nothing-decided` that
  costs a point on the other four is a loss the leaderboard will show you and
  the individual case will not.
- **Do not average away a tier.** `fast` is a real machine somebody bought. The
  headline weights it at 25% and flags any variant that collapses there; a
  prompt that only works on 9B has not been improved, it has been narrowed.
- **Do not judge with the key open.** See step 6.
- **Do not add a rule for a failure that happened once.** Greedy decoding makes
  a single run reproducible, not representative.
- **Do not let the prompt absorb the schema.** The JSON schema is already
  appended to every system prompt by `mlx_backend._with_json_instruction`.
  Restating field names in prose spends tokens saying what the model was already
  told, twice.
