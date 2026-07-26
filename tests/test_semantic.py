"""Tests for semantic word coloring."""

from piko.skills.captions.semantic_colors import get_semantic
from piko.skills.captions.styles import STYLES


def sem(word: str) -> tuple[str, str]:
    """get_semantic that fails the test instead of returning None."""
    result = get_semantic(word)
    assert result is not None, f"expected a semantic match for {word!r}"
    return result


def test_english_colors():
    assert get_semantic("green") == ("#34C759", "\U0001f7e2")
    assert get_semantic("Blue,") == ("#0A84FF", "\U0001f535")
    assert get_semantic("RED") == ("#FF3B30", "\U0001f534")


def test_russian_colors_inflected():
    # Stem matching must cover Russian inflection
    assert sem("зелёный")[0] == "#34C759"
    assert sem("зеленого")[0] == "#34C759"
    assert sem("синим")[0] == "#0A84FF"
    assert sem("красную")[0] == "#FF3B30"
    assert sem("жёлтая")[0] == "#FFD60A"


def test_semantic_objects():
    assert sem("огонь")[1] == "\U0001f525"
    assert sem("water")[0] == "#339CFF"
    assert sem("прибыль")[1] == "\U0001f4c8"


def test_non_semantic_words():
    assert get_semantic("hello") is None
    assert get_semantic("привет") is None
    assert get_semantic("") is None


def test_styles_paint_semantic_words():
    """Every style must inject the semantic color into the ASS text."""
    words = [
        {
            "word": " the",
            "start": 0.0,
            "end": 0.2,
            "probability": 0.9,
            "is_keyword": False,
            "keyword_score": 0,
        },
        {
            "word": " green",
            "start": 0.2,
            "end": 0.6,
            "probability": 0.9,
            "is_keyword": False,
            "keyword_score": 0,
            "semantic_color": "#34C759",
        },
    ]
    # #34C759 -> ASS BGR &H0059C734&
    for name, cls in STYLES.items():
        style = cls(1920, 1080)
        texts = " ".join(e.text for e in style.generate_events(words))
        assert "59C734" in texts, f"{name}: semantic color missing in {texts}"
