"""Keyword detection based on Whisper confidence scores, pauses, and duration."""

from __future__ import annotations

from statistics import median

STOP_WORDS = {
    # English
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could",
    "should", "may", "might", "shall", "can", "need", "and", "but", "or",
    "nor", "not", "so", "yet", "both", "for", "with", "from", "into",
    "about", "that", "this", "these", "those", "its", "his", "her", "our",
    "your", "their", "they", "them", "him", "she", "who", "which", "what",
    "when", "where", "how", "all", "each", "every", "some", "any", "few",
    "more", "most", "other", "than", "then", "just", "also", "very",
    "too", "here", "there", "now", "only", "still", "even",
    # Russian
    "и", "в", "во", "не", "что", "он", "на", "я", "с", "со", "как",
    "а", "то", "все", "она", "так", "его", "но", "да", "ты", "к", "у",
    "же", "вы", "за", "бы", "по", "только", "её", "мне", "было", "вот",
    "от", "меня", "ещё", "нет", "уже", "вам", "при", "нас", "до", "это",
    "мы", "них", "тем", "чем", "там", "тут", "где", "если", "когда",
    "чтобы", "хотя", "или", "ни", "для", "без", "над", "под", "между",
}

# Thresholds
CONFIDENCE_THRESHOLD = 0.92
PAUSE_THRESHOLD = 0.3  # seconds
DURATION_MULTIPLIER = 1.5
MIN_WORD_LENGTH = 3
MIN_SCORE = 2  # out of 3 signals


def detect_keywords(segments: list[dict]) -> list[dict]:
    """Detect keywords from Whisper transcription segments.

    Uses three signals (NOT TF-IDF):
    1. High confidence (>= 0.92) — word clearly pronounced (emphasis)
    2. Pause >= 0.3s before word — dramatic pause
    3. Duration >= 1.5x median — speaker stretches the word

    Returns flat list of words with added 'is_keyword' and 'keyword_score' fields.
    """
    all_words = []
    for seg in segments:
        all_words.extend(seg.get("words", []))

    if not all_words:
        return []

    durations = [w["end"] - w["start"] for w in all_words]
    median_duration = median(durations) if durations else 0.5

    results = []
    for i, word in enumerate(all_words):
        score = 0
        clean = word["word"].strip().strip(".,!?;:\"'()-")

        # Signal 1: high confidence = clearly pronounced
        if word.get("probability", 0) >= CONFIDENCE_THRESHOLD:
            score += 1

        # Signal 2: pause before word
        if i > 0:
            pause = word["start"] - all_words[i - 1]["end"]
            if pause >= PAUSE_THRESHOLD:
                score += 1

        # Signal 3: elongated pronunciation
        duration = word["end"] - word["start"]
        if duration >= median_duration * DURATION_MULTIPLIER:
            score += 1

        is_keyword = (
            score >= MIN_SCORE
            and len(clean) >= MIN_WORD_LENGTH
            and clean.lower() not in STOP_WORDS
        )

        results.append({
            **word,
            "is_keyword": is_keyword,
            "keyword_score": score,
        })

    return results
