"""Tests for subtitle style generation."""

import pysubs2

from piko.styles import STYLES


SAMPLE_WORDS = [
    {"word": " This", "start": 0.0, "end": 0.3, "probability": 0.8,
     "is_keyword": False, "keyword_score": 0},
    {"word": " is", "start": 0.3, "end": 0.5, "probability": 0.9,
     "is_keyword": False, "keyword_score": 0},
    {"word": " AMAZING", "start": 0.6, "end": 1.2, "probability": 0.95,
     "is_keyword": True, "keyword_score": 3, "emoji": "\U0001f525"},
    {"word": " content", "start": 1.3, "end": 1.7, "probability": 0.85,
     "is_keyword": False, "keyword_score": 1},
    {"word": " for", "start": 1.8, "end": 2.0, "probability": 0.9,
     "is_keyword": False, "keyword_score": 0},
    {"word": " you", "start": 2.1, "end": 2.4, "probability": 0.88,
     "is_keyword": False, "keyword_score": 0},
]


def test_all_styles_registered():
    """All 5 styles should be in the registry."""
    assert set(STYLES.keys()) == {"mrbeast", "hormozi", "tiktok", "karaoke", "minimal"}


def test_each_style_generates_events():
    """Each style should produce at least one ASS event."""
    for name, cls in STYLES.items():
        style = cls(1920, 1080)
        styles_dict = style.get_styles()
        assert len(styles_dict) > 0, f"{name}: no styles returned"

        events = style.generate_events(SAMPLE_WORDS)
        assert len(events) > 0, f"{name}: no events generated"

        for event in events:
            assert isinstance(event, pysubs2.SSAEvent)
            assert event.start >= 0
            assert event.end > event.start
            assert len(event.text) > 0


def test_mrbeast_keyword_color():
    """MrBeast style should color keywords yellow."""
    style = STYLES["mrbeast"](1920, 1080)
    events = style.generate_events(SAMPLE_WORDS)
    # At least one event should contain yellow color tag
    texts = " ".join(e.text for e in events)
    assert "\\c&H00FFFF&" in texts  # yellow in BGR


def test_hormozi_uppercases():
    """Hormozi style should uppercase all text."""
    style = STYLES["hormozi"](1920, 1080)
    events = style.generate_events(SAMPLE_WORDS)
    for event in events:
        # Extract raw text (strip ASS tags)
        import re
        raw = re.sub(r"\{[^}]*\}", "", event.text)
        # Should be all uppercase (ignoring emojis and spaces)
        alpha_chars = [c for c in raw if c.isalpha()]
        assert all(c.isupper() for c in alpha_chars), f"Not uppercase: {raw}"


def test_tiktok_word_by_word():
    """TikTok style should generate multiple events per line (word-by-word)."""
    style = STYLES["tiktok"](1920, 1080)
    events = style.generate_events(SAMPLE_WORDS)
    # TikTok generates one event per word in each line, so more events than words/5
    assert len(events) >= len(SAMPLE_WORDS)


def test_karaoke_kf_tags():
    """Karaoke style should include \\kf timing tags."""
    style = STYLES["karaoke"](1920, 1080)
    events = style.generate_events(SAMPLE_WORDS)
    for event in events:
        assert "\\kf" in event.text


def test_minimal_italic_keywords():
    """Minimal style should use italic for keywords."""
    style = STYLES["minimal"](1920, 1080)
    events = style.generate_events(SAMPLE_WORDS)
    texts = " ".join(e.text for e in events)
    assert "\\i1" in texts


def test_generate_full_ass_file():
    """Generate a complete ASS file and verify it's valid."""
    from piko.subtitle_generator import generate_subtitles

    segments = [{"words": SAMPLE_WORDS}]
    subs, emoji_timeline = generate_subtitles(segments, style_name="mrbeast")

    assert isinstance(subs, pysubs2.SSAFile)
    assert len(subs.events) > 0
    assert "MrBeast" in subs.styles
    assert isinstance(emoji_timeline, list)
