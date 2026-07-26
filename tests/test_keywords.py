"""Tests for keyword detection."""

from piko.skills.captions.keyword_detector import detect_keywords


def _make_segments(words_data: list[tuple]) -> list[dict]:
    """Helper: create segments from (word, start, end, probability) tuples."""
    words = [
        {"word": w, "start": s, "end": e, "probability": p}
        for w, s, e, p in words_data
    ]
    return [{"words": words}]


def test_empty_input():
    assert detect_keywords([]) == []
    assert detect_keywords([{"words": []}]) == []


def test_high_confidence_long_duration_detected():
    """Word with high confidence + long duration = keyword."""
    segments = _make_segments([
        (" the", 0.0, 0.2, 0.5),      # short, low conf
        (" quick", 0.3, 0.5, 0.6),     # short, low conf
        (" AMAZING", 0.6, 1.4, 0.95),  # long + high conf = keyword
        (" thing", 1.5, 1.7, 0.7),     # short, low conf
    ])
    results = detect_keywords(segments)
    assert len(results) == 4
    # "AMAZING" has high conf (0.95 >= 0.92) + long duration (0.8s vs median ~0.2s)
    assert results[2]["is_keyword"] is True
    assert results[2]["keyword_score"] >= 2


def test_pause_before_word_detected():
    """Word after a long pause + high confidence = keyword."""
    segments = _make_segments([
        (" hello", 0.0, 0.3, 0.9),
        (" world", 0.4, 0.6, 0.9),
        # Big pause (1.0s) before "SECRET"
        (" SECRET", 1.6, 2.2, 0.95),  # pause + high conf + long
        (" word", 2.3, 2.5, 0.9),
    ])
    results = detect_keywords(segments)
    secret = results[2]
    assert secret["is_keyword"] is True
    assert secret["keyword_score"] >= 2


def test_stop_words_filtered():
    """Stop words are never keywords even with high scores."""
    segments = _make_segments([
        (" the", 0.0, 0.8, 0.99),    # stop word, even with high conf + long
        (" cat", 1.5, 2.3, 0.99),    # NOT stop word, high conf + long + pause
    ])
    results = detect_keywords(segments)
    assert results[0]["is_keyword"] is False  # "the" is a stop word
    assert results[1]["is_keyword"] is True   # "cat" should be keyword


def test_short_words_filtered():
    """Words shorter than 3 chars are never keywords."""
    segments = _make_segments([
        (" go", 0.0, 0.8, 0.99),     # only 2 chars
        (" run", 1.5, 2.3, 0.99),    # 3 chars, should pass
    ])
    results = detect_keywords(segments)
    assert results[0]["is_keyword"] is False  # "go" is too short
    assert results[1]["is_keyword"] is True   # "run" passes length check


def test_keyword_score_field_present():
    """All results should have keyword_score field."""
    segments = _make_segments([
        (" hello", 0.0, 0.3, 0.9),
        (" world", 0.4, 0.6, 0.5),
    ])
    results = detect_keywords(segments)
    for r in results:
        assert "keyword_score" in r
        assert "is_keyword" in r
        assert isinstance(r["keyword_score"], int)
