# Writing a candidate

What actually moves the number on the models Piko ships. Read before writing a
variant; the failure modes below are the ones this bench was built to catch.

## Know what is already true before you write a word

- **The schema is appended for you.** `mlx_backend._with_json_instruction`
  glues the full JSON Schema onto every system prompt, including every key in
  `required`. Naming fields again in prose spends tokens telling the model
  something it is about to be told properly. Say what a field *means*, never
  that it exists.
- **Thinking is off.** `CHAT_TEMPLATE_KWARGS` sets `enable_thinking: False`, so
  a prompt asking the model to "think step by step" is asking for tokens it will
  spend inside the answer. On a JSON target that is not slower reasoning, it is
  a broken object.
- **Decoding is greedy** (temperature 0, `bench/prompts` fixes the seed too), so
  a run is reproducible. A single bad output is a real property of the prompt,
  not luck — but it is also one case, not a pattern.
- **The prompt is paid per chunk.** A 30-minute meeting is ~16 extraction calls.
  Fifty extra words is fifty words times sixteen, every meeting, forever.
- **These are Qwen3.5 at 4-bit, 2B to 9B.** Local models are far more sensitive
  to prompt structure than frontier models, which have been post-trained into
  forgiving sloppy instructions. Structure is not decoration here.

## What works

**XML-tagged sections.** `<rules>`, `<definitions>`, `<output>`. They survive a
long transcript in the same context far better than prose paragraphs, which
small models drift away from once the input dominates the window. This is why
every shipped prompt already looks like this.

**Definitions with a contrast attached.** The errors this bench catches are
almost all category-boundary errors: a proposal filed as a decision, a problem
filed as a task, a speaker label written into `owner`. A boundary is taught in
six words —

```
decision: a choice that was settled. "We ship Thursday" is one. "We could shard it" is not.
```

— and that is cheaper and sharper than a paragraph explaining what a decision is.

**Instructing the empty answer instead of permitting it.** "Leave a list empty
rather than padding it" is a permission, and a permission is what a model
declines to use. "Most parts of most meetings settle nothing; an empty list is
the right answer there" states the expectation. Same length, different verb mood.

**Naming the target language outright.** `{language}` is filled with a language
*name*, and the instruction says "whatever language these instructions are in" —
because an English system prompt over a Russian transcript pulls the answer into
English below 4B. This is a real, measured failure, not a hypothetical.

**Worked examples for arithmetic-shaped tasks.** `due` converts phrases to
dates; six input → output pairs teach the null case better than any rule about
"unresolvable" can. Use a different anchor date and different phrases from the
eval set — an example that contains a test answer measures nothing. Disclose the
overlap that remains, because a task with six phrase families cannot avoid it.

**An ordered procedure, where the task really is sequential.** "Read the lines
once, in order. For each ask: …" gives structure without thinking tokens. Test
it rather than assuming it: it is also the easiest way to make a model narrate.

## What does not

**Prohibitions without an alternative.** "Never invent owners" tells the model
what not to do and leaves the space open. "`owner` is a person named in the
transcript, null when nobody was named" closes it. Prefer the shape that says
where to go.

**Restating a rule for emphasis.** Two rules about hallucination are not twice
as strong; they are two rules to weigh against each other, and a small model
will follow whichever came last.

**Rules about tags that are not in the message.** `NOTES_RULES` is appended only
when the call actually carries notes, and that is not an optimisation — a rule
describing `<user_notes>` in a message with no `<user_notes>` invites the model
to produce one. Anything conditional must be conditional in the code too.

**Persona and courtesy.** "You are an expert meeting analyst with 20 years of
experience", "take a deep breath", "this is very important to my career". These
are frontier-model folklore and they cost tokens on a 2B model that needs them
for the transcript.

**Restating the output format three times.** One `<output>` line. The schema is
already attached and `generate_json` already retries on a fenced or prose-wrapped
reply.

## Structural rules of thumb

- **Most-violated rule first.** Attention to a rule decays with its distance
  from the input on small models. If the bench says padding is the failure, the
  anti-padding rule does not belong eighth of eight.
- **One rule, one line.** A rule that wraps to three lines is two rules.
- **Ceilings must say they are ceilings.** "at most 2000 characters" reads to a
  model as a target. `reduce` writing 1,900 characters about an eight-line call
  is that failure, and it is why one of the variants states length follows the
  meeting rather than the limit.
- **Cut before you add.** If a candidate needs a new rule, look first for the
  rule it makes redundant. The prompts here are short; keeping them short is a
  result, not a constraint.

## The loop this sits in

The method is GEPA-shaped ([ICLR 2026](https://arxiv.org/abs/2507.19457)):
reflect in natural language on failing traces, mutate, keep a Pareto frontier of
candidates rather than a single champion. Two adaptations for this repo:

- **Section-local mutation** ([Modular Prompt
  Optimization](https://arxiv.org/pdf/2601.04055)) — change one block per
  candidate, and name the file after the hypothesis. A rewrite that wins tells
  you nothing about which of its six changes did it.
- **Lexicographic gates, not a pure weighted sum.** Multi-objective optimisation
  against a judge has a documented failure mode where objectives trade against
  each other in ways nobody sanctioned ([When Gradients
  Collide](https://arxiv.org/pdf/2605.26046)). Faithfulness and citation
  validity are not tradeable here, so they sit outside the sum as gates.

## Failure catalogue

The things this bench has actually caught, so a new candidate can be checked
against them before it costs a run:

| symptom | what it usually is |
|---|---|
| items come back as bare strings, no `ref` | the prompt described the fields in prose and the model followed the prose over the schema |
| empty lists never happen | the empty case is a permission, or it is the last rule |
| speaker label in `owner` | `owner`'s definition does not name the labels it must exclude |
| Russian transcript, English answer | the language rule is late, or does not name the language |
| `summary` is `brief` again, longer | the two are defined by length instead of by what each is *for* |
| a decision assembled from a list of options | no contrast in the definition of a decision |
| a deadline invented for "as soon as possible" | urgency read as a date; the null case needs an example, not a rule |
