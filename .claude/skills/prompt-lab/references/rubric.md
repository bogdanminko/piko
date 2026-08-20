# The score

`bench/prompts/score.py` is this document executed. If you change one, change
both.

```
PPS = 60 x quality + 15 x reliability + 15 x efficiency + 10 x simplicity
```

each term in 0..1, so PPS runs 0–100. Computed per tier, then

```
headline = 0.25 x fast + 0.50 x balanced + 0.25 x quality-tier
```

`balanced` carries the round because it is the default tier. The other two are
there to catch a prompt that only works on one size of model — a variant more
than 20 points below its own headline on `fast` is flagged **tier-fragile** and
does not ship, whatever it scored.

## The gates come first

Three conditions, checked per (variant, tier) across every case. Fail one and
the variant is **unfit**: it gets no PPS at all and is ranked below everything
that passed.

| gate | threshold | why it is a gate and not a penalty |
|---|---|---|
| parses | ≥ 95% of runs yield a JSON object | an unparseable reply is not a worse summary, it is no summary — the stage is lost |
| citations exist | **zero** refs naming a line that was never shown | the product promise is that any item can be clicked back to its second. One invented number breaks it |
| language | 100% of parsed runs answer in the transcript's language | a summary in the wrong language is unreadable to the person who held the meeting |

Lexicographic, not folded into the weighted sum, and that is the whole point. A
weighted score offers an exchange rate between "invented a citation" and "wrote
nicely", and given one, an optimiser will eventually take it. There is no rate
at which that trade is acceptable here.

An item with **no** ref is a different failure and is *not* gated: nothing was
falsified, the item is simply dropped by `_resolve` before it reaches the screen.
It costs reliability and coverage instead.

## quality — judged, 0..1

Four axes, each scored 0–5 per sample, combined as

```
quality = (0.35 F + 0.25 C + 0.20 B + 0.20 A) / 5
```

Faithfulness leads because an untrue summary is worse than no summary. The rest
describe how good a true one is.

Judge **comparatively, inside one case**: all variants' outputs for a meeting sit
in the same packet, shuffled, under opaque ids. Score them against each other in
one sitting. Absolute scoring drifts between sessions; relative ordering within a
packet does not.

### F — faithfulness (0.35)

Is every claim in the transcript, and is every claim in the transcript
represented as what it actually was?

| | |
|---|---|
| 5 | every item traceable to its cited line; proposals stay proposals; nobody is named who was not named; no deadline exists that was not spoken |
| 4 | one item overstates its evidence — a hedged agreement written as a firm decision |
| 3 | one clear misattribution: an owner nobody assigned, a decision from a list of options |
| 2 | several, or one invented fact stated with confidence |
| 0–1 | a person, a number or a commitment that appears nowhere in the input |

Where a case carries typed user notes, a note **outranks the transcript**. An
output that keeps the ASR's spelling of a name the note corrects loses a point
here, not a stylistic one: it ignored the only input a human actually wrote.

### C — coverage (0.25)

Against the case's `must_find`. Judge what a reader would have to go back to the
recording for.

| | |
|---|---|
| 5 | every `must_find` present, in the right list, cited near the right lines |
| 4 | one minor item missing, or one filed under the wrong list |
| 3 | one thing that mattered is gone |
| 2 | half the meeting |
| 0–1 | the summary is about a different conversation |

An item dropped because it had no `ref` is missing. It never reaches the screen.

### B — bullshit-free (0.20)

The axis with the most room to go soft, so it is defined by symptoms and not by
taste. Start at 5 and deduct for each of these that is present:

1. **Content-free sentences.** True of every meeting ever held. "The team
   discussed several topics and agreed on next steps."
2. **Padded lists.** A weak item admitted to make a list look substantial — a
   restated fact filed as a decision, an "action item" nobody agreed to.
3. **Hedging and meta.** "Based on the transcript…", "It appears that…". The
   reader knows where it came from; that is what the timecode is for.
4. **Abstraction over what was said.** "alignment on the release timeline" where
   the transcript said "ship Thursday, not Friday". Corporate register is the
   most common form.
5. **The brief written twice.** A `summary` that restates `brief` at greater
   length instead of telling the reader how the discussion went.
6. **Length that follows the ceiling rather than the meeting.** 1,900 characters
   about an eight-line call.

5 = none of them. 3 = one, mild. 1 = the output reads as a performance of
summarizing. `metrics.py` counts symptoms 3 and 5 mechanically and reports them
in `hedges` / `vague` / `brief_echo` — read those, then look for the rest
yourself, because the ones that matter most are not phrase-matchable.

### A — actionability (0.20)

Can the reader do something with it without going back to the audio?

| | |
|---|---|
| 5 | tasks read as tasks (a verb, an object), owners where a person was named and null where not, deadlines in the words they were spoken in, decisions stating the choice rather than the topic |
| 4 | one item is a topic in a task's clothing ("discuss the storage options") |
| 3 | owners missing where the transcript names one, or deadlines dropped |
| 2 | a list of subjects rather than of things to do |
| 0–1 | nothing usable |

A speaker label in `owner` ("You", "Participants") is capped at 3 regardless: it
is stripped in production, so it silently becomes an ownerless task.

## reliability — mechanical, 0..1

Averaged over runs, starting at 1.0 and deducting:

| | |
|---|---|
| −0.20 | a required key missing or a list that is not a list |
| −0.15 | per list the case says must be empty and is not |
| −0.10 | per trap hit, per owner leak, per over-budget field |
| −0.05 | per unknown owner, per count out of range, per hedge/vague phrase |
| −0.15 | `brief_echo` ≥ 0.5 — half the brief reappears verbatim in the summary |
| −0.5 × share | of items carrying no usable ref, which never reach the screen |

For `due`: `(right − 0.5 × invented) / total`. An invented date is charged twice
because it is the error that puts a commitment nobody made into somebody's
calendar; a missed one only leaves a field to type.

## efficiency — 0..1

`min(1, best_median_generation_tokens / this_median)`, compared **within a tier**.

This is the "does not think for a long time about nothing" term. Generation
tokens, not wall clock: this machine drifts about 19% over a twenty-minute run
(measured in `bench/asr`), which is larger than any prompt-level effect, so wall
clock is recorded and never ranked on. Token counts are exact.

## simplicity — 0..1

`min(1, shortest_passing_prompt_chars / this_prompt_chars)`.

Only 10 points, and deliberately so — it is a tie-breaker, not an objective. It
exists because every other term is happy to accept a longer prompt, and someone
has to price the cost of one: more for a 2B model to lose the thread in, more
tokens on every chunk of every meeting, one more clause to contradict another.

## Reading a result

- **Same headline, different lengths** → ship the shorter one. Always.
- **Wins on `quality`, loses on `reliability`** → it writes well and breaks the
  shape. Usually one rule too many; try the same idea stated in fewer words.
- **Wins on `balanced` and `quality`, collapses on `fast`** → tier-fragile. The
  prompt is too long or too indirect for 2B. Not shippable as the default.
- **Everything within ~2 points** → nothing was learned. Do not ship noise; go
  back to step 2 with a sharper diagnosis, or declare the prompt finished.
