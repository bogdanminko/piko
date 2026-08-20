"""Who said it — decided by comparing the two recorded tracks.

Because the recorder keeps the microphone and the system output as separate,
sample-aligned tracks, attribution is a level comparison rather than
diarization: for each transcript segment, whichever track carries more energy
owns it. Levels are normalised per track first (a laptop mic and a conference
call rarely arrive at the same loudness), so the comparison survives a quiet
speaker or a hot input gain.

On its own this separates *sides*, not individual people. Naming which of them
spoke is a second, optional step: `diarize.py` runs a model over the far-end
track and, when it answers, "them" is refined into "them-1", "them-2"… The
side decision is never revised by that model — it is physical evidence, and a
model can only make it less certain.
"""

from __future__ import annotations

import numpy as np

from .audio import RAW_RATE
from .diarize import Turn, renumber

SPEAKER_ME = "me"
SPEAKER_THEM = "them"
# Imported files carry no side tracks — claiming they are "you" would be a
# guess, and a summary built on guessed attribution is not verifiable.
SPEAKER_UNKNOWN = "unknown"

SPEAKER_NAMES = {SPEAKER_ME: "You", SPEAKER_THEM: "Participants", SPEAKER_UNKNOWN: "Speaker"}

# "them-2" is the second far-end voice; the bare "them" stays for every segment
# diarization did not resolve, so a partial answer degrades to the old one
# rather than to a wrong one.
_THEM_PREFIX = f"{SPEAKER_THEM}-"
# An imported file has no sides at all, so its voices cannot be called "them":
# the person who imported it is somewhere in that mix too. They are numbered
# without being placed — "Speaker 2", not "Participant 2" and never "You".
_ANON_PREFIX = f"{SPEAKER_UNKNOWN}-"

# Below this a frame is room tone, not speech.
_NOISE_FLOOR = 1e-4
# How much louder (in dex, i.e. log10 units) one side must be to claim a
# segment. Inside the band the levels have not decided anything and the ladder
# in `attribute()` falls through to the next kind of evidence.
_MARGIN = 0.08

# How much of an undecided segment a far-end turn must cover before that turn
# claims it. Diarization heard an actual voice on the system track, which is
# positive evidence; carrying the previous label over is merely inertia, so
# anything past half the segment outranks it.
_FAR_END_COVER = 0.5


def _reference_level(samples: np.ndarray, rate: int) -> float:
    """Typical speech level of a track: 90th percentile of 100 ms frame RMS."""
    frame = max(1, rate // 10)
    if samples.size < frame:
        return 0.0
    usable = samples[: samples.size // frame * frame].reshape(-1, frame)
    rms = np.sqrt((usable**2).mean(axis=1))
    loud = rms[rms > _NOISE_FLOOR]
    if loud.size == 0:
        return 0.0
    return float(np.percentile(loud, 90))


def _segment_rms(samples: np.ndarray, start: float, end: float, rate: int) -> float:
    first = max(0, int(start * rate))
    last = min(samples.size, int(end * rate))
    if last <= first:
        return 0.0
    chunk = samples[first:last]
    return float(np.sqrt((chunk**2).mean()))


def attribute(
    segments: list[dict],
    mic: np.ndarray,
    system: np.ndarray,
    rate: int = RAW_RATE,
    turns: list[Turn] | None = None,
) -> list[dict]:
    """Tag every segment with a speaker key and how confident that call is.

    Returns new dicts: {start, end, text, speaker, speaker_confidence}.

    `turns` is the optional far-end diarization from `diarize.diarize()`. It
    does two jobs: it narrows a far-side segment to the individual voice that
    owns most of it, and it breaks the ties the levels cannot — see the ladder
    of evidence in the loop below.
    """
    numbering = renumber(turns or [])

    if mic.size == 0 and system.size == 0:
        # An import: the sides are unknowable, but the voices need not be. Any
        # diarization here was run over the mix, so its turns number people
        # without claiming which one is the listener.
        return [
            _tagged(
                segment,
                _voice(
                    float(segment.get("start", 0.0)),
                    float(segment.get("end", segment.get("start", 0.0))),
                    turns,
                    numbering,
                    prefix=_ANON_PREFIX,
                    fallback=SPEAKER_UNKNOWN,
                ),
                0.0,
            )
            for segment in segments
        ]
    if system.size == 0:
        return [_tagged(segment, SPEAKER_ME, 1.0) for segment in segments]
    if mic.size == 0:
        # Nothing to compare against, so every segment is theirs — but which of
        # them is still answerable, and the far-end track is exactly what was
        # recorded here.
        return [
            _tagged(
                segment,
                _voice(
                    float(segment.get("start", 0.0)),
                    float(segment.get("end", segment.get("start", 0.0))),
                    turns,
                    numbering,
                ),
                1.0,
            )
            for segment in segments
        ]

    mic_reference = _reference_level(mic, rate) or _NOISE_FLOOR
    system_reference = _reference_level(system, rate) or _NOISE_FLOOR

    result: list[dict] = []
    # No default side. Starting at "me" meant a first segment nobody could
    # decide was silently credited to the person holding the laptop.
    previous: str | None = None
    for segment in segments:
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        mic_level = _segment_rms(mic, start, end, rate) / mic_reference
        system_level = _segment_rms(system, start, end, rate) / system_reference

        score = float(np.log10((system_level + 1e-6) / (mic_level + 1e-6)))
        if score > _MARGIN:
            speaker = SPEAKER_THEM
        elif score < -_MARGIN:
            speaker = SPEAKER_ME
        elif _covered(start, end, turns) >= _FAR_END_COVER:
            # The levels tied, but a voice was heard on the far-end track for
            # most of this segment. Heard beats inherited.
            speaker = SPEAKER_THEM
        elif previous is not None:
            # Nothing new to go on: whoever was talking is still talking, which
            # is what stops one sentence from changing hands mid-way.
            speaker = previous
        else:
            # First segment of the call and every signal is a tie. The sign of
            # the ratio is weak, but it is evidence; a fixed side is not.
            speaker = SPEAKER_THEM if score > 0 else SPEAKER_ME
        previous = speaker

        if speaker == SPEAKER_THEM:
            speaker = _voice(start, end, turns, numbering)

        # How far apart the two tracks were, and nothing else: 0 at the
        # decision boundary, 1 once one side is ~10× louder. A segment the
        # levels tied on keeps a low number even when diarization then settled
        # it confidently — this field answers "how separated were the tracks",
        # which is the question the recorder can always answer.
        confidence = min(1.0, abs(score))
        result.append(_tagged(segment, speaker, confidence))
    return result


def _covered(start: float, end: float, turns: list[Turn] | None) -> float:
    """Fraction of [start, end) that any far-end voice was speaking over.

    Speakers are unioned rather than summed: two people talking at once still
    covers one segment once, and overlap is evidence *for* the far side, not
    double the evidence.
    """
    if not turns or end <= start:
        return 0.0

    covered = 0.0
    reached = start
    for turn in sorted(turns, key=lambda turn: turn.start):
        first = max(turn.start, reached)
        last = min(turn.end, end)
        if last > first:
            covered += last - first
            reached = last
        if reached >= end:
            break
    return covered / (end - start)


def _voice(
    start: float,
    end: float,
    turns: list[Turn] | None,
    numbering: dict[int, int],
    prefix: str = _THEM_PREFIX,
    fallback: str = SPEAKER_THEM,
) -> str:
    """Which numbered voice owns [start, end) — or `fallback` if none does.

    Whoever holds the most of the segment wins it. A Whisper segment can span a
    handover, so a majority is the honest reading of an interval that may have
    two owners; silence and a segment no turn touches keep the unnumbered
    label, which is vaguer but never wrong.
    """
    if not turns:
        return fallback

    held: dict[int, float] = {}
    for turn in turns:
        overlap = min(end, turn.end) - max(start, turn.start)
        if overlap > 0:
            held[turn.speaker] = held.get(turn.speaker, 0.0) + overlap
    if not held:
        return fallback

    owner = max(held, key=lambda speaker: held[speaker])
    return f"{prefix}{numbering[owner]}"


def speaker_names(segments: list[dict]) -> dict[str, str]:
    """Display names for exactly the speaker keys a transcript actually uses.

    Built from the segments rather than declared up front, because how many
    people the far end turned out to hold is only known after diarization.
    """
    names = dict(SPEAKER_NAMES)
    keys = [str(segment.get("speaker", "")) for segment in segments]
    numbers = _numbers(keys, _THEM_PREFIX)
    for number in numbers:
        names[f"{_THEM_PREFIX}{number}"] = f"Participant {number}"
    for number in _numbers(keys, _ANON_PREFIX):
        names[f"{_ANON_PREFIX}{number}"] = f"Speaker {number}"
    # With every far-end segment resolved to a person, the collective label is
    # dead weight in the legend; keep it only while something still wears it.
    if numbers and SPEAKER_THEM not in keys:
        names.pop(SPEAKER_THEM, None)
    return names


def _numbers(keys: list[str], prefix: str) -> list[int]:
    """The distinct speaker numbers used under one prefix, in order."""
    return sorted({int(key.removeprefix(prefix)) for key in keys if key.startswith(prefix)})


def _tagged(segment: dict, speaker: str, confidence: float) -> dict:
    start = float(segment.get("start", 0.0))
    return {
        "start": round(start, 3),
        "end": round(float(segment.get("end", start)), 3),
        "text": str(segment.get("text", "")).strip(),
        "speaker": speaker,
        "speaker_confidence": round(confidence, 3),
    }
