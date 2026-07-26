"""Who said it — decided by comparing the two recorded tracks.

Because the recorder keeps the microphone and the system output as separate,
sample-aligned tracks, attribution is a level comparison rather than
diarization: for each transcript segment, whichever track carries more energy
owns it. Levels are normalised per track first (a laptop mic and a conference
call rarely arrive at the same loudness), so the comparison survives a quiet
speaker or a hot input gain.

The limit of this approach is honest and known: it separates *sides*, not
individual people. Everyone on the far end is "them".
"""

from __future__ import annotations

import numpy as np

from .audio import RAW_RATE

SPEAKER_ME = "me"
SPEAKER_THEM = "them"
# Imported files carry no side tracks — claiming they are "you" would be a
# guess, and a summary built on guessed attribution is not verifiable.
SPEAKER_UNKNOWN = "unknown"

SPEAKER_NAMES = {SPEAKER_ME: "You", SPEAKER_THEM: "Participants", SPEAKER_UNKNOWN: "Speaker"}

# Below this a frame is room tone, not speech.
_NOISE_FLOOR = 1e-4
# How much louder (in dex, i.e. log10 units) one side must be to claim a
# segment. Inside the band the previous speaker keeps talking, which stops
# short segments from flip-flopping mid-sentence.
_MARGIN = 0.08


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
) -> list[dict]:
    """Tag every segment with a speaker key and how confident that call is.

    Returns new dicts: {start, end, text, speaker, speaker_confidence}.
    """
    if mic.size == 0 and system.size == 0:
        return [_tagged(segment, SPEAKER_UNKNOWN, 0.0) for segment in segments]
    if system.size == 0:
        return [_tagged(segment, SPEAKER_ME, 1.0) for segment in segments]
    if mic.size == 0:
        return [_tagged(segment, SPEAKER_THEM, 1.0) for segment in segments]

    mic_reference = _reference_level(mic, rate) or _NOISE_FLOOR
    system_reference = _reference_level(system, rate) or _NOISE_FLOOR

    result: list[dict] = []
    previous = SPEAKER_ME
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
        else:
            speaker = previous
        previous = speaker

        # 0 at the decision boundary, 1 once one side is ~10× louder.
        confidence = min(1.0, abs(score))
        result.append(_tagged(segment, speaker, confidence))
    return result


def _tagged(segment: dict, speaker: str, confidence: float) -> dict:
    start = float(segment.get("start", 0.0))
    return {
        "start": round(start, 3),
        "end": round(float(segment.get("end", start)), 3),
        "text": str(segment.get("text", "")).strip(),
        "speaker": speaker,
        "speaker_confidence": round(confidence, 3),
    }
