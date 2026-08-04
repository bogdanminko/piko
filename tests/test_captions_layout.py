"""Caption geometry, card boundaries and the plain .srt/.vtt export.

These cover the things that were wrong on real footage rather than on the
1080p landscape clip every style was calibrated against: vertical video,
4K, silences, sentences, and the export nobody could reach.
"""

from __future__ import annotations

from piko.skills.captions.plain import (
    MAX_CHARS_PER_LINE,
    MIN_DURATION,
    build_plain_subtitles,
    wrap_lines,
)
from piko.skills.captions.styles import STYLES
from piko.skills.captions.styles.base import escape_ass, group_words_into_cards

LANDSCAPE = (1920, 1080)
PORTRAIT = (1080, 1920)
UHD = (3840, 2160)


def _words(*spans: tuple[str, float, float]) -> list[dict]:
    return [{"word": w, "start": s, "end": e} for w, s, e in spans]


# --- Geometry ---


def test_landscape_reproduces_the_calibrated_pixels():
    """The 1080p look is unchanged: fractions were derived from it."""
    style = STYLES["mrbeast"](*LANDSCAPE)
    assert style.font_size == 72
    assert style.margin_v == 60
    assert style.outline == 4.0


def test_font_scales_with_frame_height():
    """A 4K master must not get 1080p-sized lettering."""
    small = STYLES["mrbeast"](*LANDSCAPE).font_size
    large = STYLES["mrbeast"](*UHD).font_size
    assert large == small * 2


def test_portrait_is_lifted_clear_of_platform_ui():
    """On 9:16 the style's own bottom margin lands under the TikTok chrome."""
    style = STYLES["mrbeast"](*PORTRAIT)
    assert style.margin_v >= int(PORTRAIT[1] * 0.12)


def test_every_style_reserves_a_side_safe_area():
    """pysubs2 defaults to 10 px, which runs text to the frame edge."""
    for name, cls in STYLES.items():
        style = cls(*PORTRAIT)
        assert style.margin_h > 10, name
        assert style.margin_h == int(round(PORTRAIT[0] * 0.05)), name


def test_geometry_reaches_the_registered_ssa_style():
    for name, cls in STYLES.items():
        style = cls(*PORTRAIT)
        for ssa in style.get_styles().values():
            assert ssa.fontsize == style.font_size, name
            assert ssa.marginv == style.margin_v, name
            assert ssa.marginl == style.margin_h, name
            assert ssa.marginr == style.margin_h, name


def test_a_named_font_is_always_resolved():
    """Never left blank for libass to guess at."""
    for name, cls in STYLES.items():
        for ssa in cls(*LANDSCAPE).get_styles().values():
            assert ssa.fontname, name


# --- Card boundaries ---


def test_a_silence_is_not_spanned_by_one_card():
    """The bug: the split was decided after the far word had been added, so
    a card containing both sides of a 30 s gap stayed on screen for 30 s."""
    words = _words((" hello", 10.0, 10.3), (" again", 40.0, 40.5))
    events = STYLES["mrbeast"](*LANDSCAPE).generate_events(words)
    assert len(events) == 2
    assert all(e.end - e.start < 1000 for e in events)


def test_a_sentence_ends_its_card():
    words = _words((" Done.", 0.0, 0.4), (" Next", 0.5, 0.8), (" one", 0.85, 1.1))
    cards = STYLES["mrbeast"](*LANDSCAPE).group_words(words)
    assert [[w["word"] for w in card] for card in cards] == [[" Done."], [" Next", " one"]]


def test_a_card_is_bounded_by_room_not_only_by_word_count():
    """Four words fit a 1920-wide frame and overflow a 1080-wide one."""
    words = _words(
        (" extraordinarily", 0.0, 0.4),
        (" complicated", 0.45, 0.9),
        (" pronunciation", 0.95, 1.4),
        (" guidelines", 1.45, 1.9),
    )
    wide = STYLES["mrbeast"](*LANDSCAPE).group_words(words)
    tall = STYLES["mrbeast"](*PORTRAIT).group_words(words)
    assert len(wide) == 1
    assert len(tall) > 1


def test_grouping_never_drops_a_word():
    words = _words(*[(f" w{i}", i * 0.5, i * 0.5 + 0.3) for i in range(40)])
    cards = group_words_into_cards(words, max_words=4, max_duration=3.0, max_chars=40)
    assert [w for card in cards for w in card] == words


def test_transcript_braces_cannot_open_an_override_block():
    assert escape_ass("{\\an8}drop") == "\\{\\an8\\}drop"
    text = STYLES["mrbeast"](*LANDSCAPE).word_text({"word": " {evil}"})
    assert "{evil}" not in text


# --- Plain export ---


def test_wrap_lines_respects_the_reading_width():
    text = wrap_lines("one two three four five six seven eight nine ten eleven")
    first = text.split("\\N")[0]
    assert len(first) <= MAX_CHARS_PER_LINE
    assert text.count("\\N") <= 1


def test_plain_export_carries_no_styling_tags():
    segments = [{"words": _words((" Hello", 0.0, 0.4), (" world.", 0.45, 0.9))}]
    subs = build_plain_subtitles(segments)
    assert subs.events
    assert all("{" not in e.text for e in subs.events)


def test_a_short_card_is_held_long_enough_to_read():
    segments = [{"words": _words((" Hi.", 0.0, 0.2))}]
    event = build_plain_subtitles(segments).events[0]
    assert event.end - event.start >= int(MIN_DURATION * 1000)


def test_holding_a_card_never_overlaps_the_next_one():
    segments = [{"words": _words((" Hi.", 0.0, 0.2), (" There.", 0.5, 0.7))}]
    events = build_plain_subtitles(segments).events
    assert len(events) == 2
    assert events[0].end <= events[1].start


def test_segments_without_word_timings_still_export():
    """Not every ASR pass returns per-word timing; those still make subtitles."""
    segments = [{"start": 0.0, "end": 2.0, "text": "No word timings here."}]
    events = build_plain_subtitles(segments).events
    assert len(events) == 1
    assert "No word timings here." in events[0].text


def test_plain_files_are_written_in_both_formats(tmp_path):
    from piko.skills.captions.plain import save_plain_subtitles

    segments = [{"words": _words((" Hello", 0.0, 0.4), (" world.", 0.45, 0.9))}]
    written = save_plain_subtitles(segments, tmp_path / "out.ass")

    assert set(written) == {"srt", "vtt"}
    assert (tmp_path / "out.srt").read_text().startswith("1\n")
    assert (tmp_path / "out.vtt").read_text().startswith("WEBVTT")
