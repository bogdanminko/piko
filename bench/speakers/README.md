# Speaker separation

Who spoke, and can we answer it without paying for a second model.

Piko answers *me vs them* without any model at all: the recorder keeps the
microphone and the system output as separate, sample-aligned tracks, so the
question is a level comparison (`skills/meeting/speakers.py`). That is the whole
answer whisper.cpp's `--diarize` gives too, and it is structurally incapable of
going further — everyone on the far end arrives mixed down one output device.

Telling *which of them* spoke therefore needs acoustics, and today that is
NVIDIA's Sortformer v1 via mlx-audio (`skills/meeting/diarize.py`) — 236 MB,
end-to-end, up to 4 far-end voices, run on the system track alone.

## The open question

Sortformer is a second model. The ASR encoder already computes rich frame-level
representations of the same audio; if speaker identity survives in them, a head
on those activations would replace the download, the RAM and the 4-speaker
ceiling in one move.

The counter-argument is that ASR training rewards the opposite: the same word
from two voices should land in the same place, so identity is nuisance variation
the encoder is trained to discard — and progressively more of it with depth,
which would make the *last* hidden state the worst possible tap point.

That is measurable rather than arguable, and it is what
[`encoder_speaker_probe.ipynb`](encoder_speaker_probe.ipynb) measures, per layer,
for **parakeet** (the model Meeting Summary is moving to) and for **whisper**.

## Why this suite gets ground truth for free

A two-track recording is a labelled dataset nobody annotated: wherever the mic
and system tracks disagree decisively, the speaker is known by physics. The
notebook scores against those segments only and drops the ties, so nothing is
measured against another model's opinion.

The limit is worth stating up front: this is *me vs them*, a two-way split of
two physically distinct channels — the easiest version of the task. Separating
three people inside the far-end track is strictly harder, so a score here is an
optimistic ceiling, not the expected result.

## Running it

Once, to build the research environment (see [`../pyproject.toml`](../pyproject.toml)
for why it is separate from the app's):

```bash
uv sync --project bench
uv run --project bench python -m ipykernel install --user \
    --name piko-bench --display-name "Piko bench (3.13)"
```

Then either open the notebook in an IDE and pick the **Piko bench (3.13)**
kernel — the notebook already asks for it by name — or run Lab:

```bash
uv run --project bench jupyter lab bench/speakers/encoder_speaker_probe.ipynb
```

Point `RECORDING` at a Piko recording folder that has `mic.m4a`, `system.m4a`
and `meeting.m4a`; an import has no side tracks and therefore no ground truth.
No cell prints transcript text — only timings, counts and scores.

Remove the kernel with `jupyter kernelspec remove piko-bench`; the environment
itself is just `bench/.venv` and can be deleted.

## Results

Not run on real audio yet. The synthetic smoke test (two tones standing in for
two voices, parakeet encoder) already shows the predicted shape — layer 0
separates them perfectly, the deepest layer lands at chance — but tones are not
speech and that number is a plumbing check, not a finding.
