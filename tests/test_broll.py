"""Unit tests for the local b-roll library and insert planner."""

from pathlib import Path

from piko.core.broll import BRollLibrary, Concept, plan_inserts


def match(lib: BRollLibrary, word: str) -> Concept:
    concept = lib.match_word(word)
    assert concept is not None, f"no concept matched {word!r}"
    return concept


def make_library(root: Path, state: Path) -> BRollLibrary:
    # "widgets"/"stash" are custom, non-built-in concepts — they exercise
    # generic folder-name + aliases.txt matching, untouched by the
    # multilingual CONCEPT_LEXICON (see test_lexicon_matches_all_languages
    # and test_legacy_folder_migrates for the built-in vocabulary).
    widgets = root / "widgets"
    widgets.mkdir(parents=True)
    (widgets / "a.mp4").touch()
    (widgets / "b.mp4").touch()
    (widgets / "aliases.txt").write_text("gadget\nblocks\n", encoding="utf-8")
    stash = root / "stash"
    stash.mkdir()
    (stash / "cash.mov").touch()
    empty = root / "empty"
    empty.mkdir()  # no clips — must be ignored
    return BRollLibrary(root=root, state_path=state)


def words(*pairs):
    return [{"words": [{"word": w, "start": t, "end": t + 0.3} for w, t in pairs]}]


def test_scan_and_match(tmp_path):
    lib = make_library(tmp_path / "lib", tmp_path / "state.json")
    assert [c.name for c in lib.concepts] == ["stash", "widgets"]

    assert match(lib, "Widget").name == "widgets"
    # Stem prefix: inflected forms match.
    assert match(lib, "widgeting").name == "widgets"
    assert lib.match_word("zzz") is None
    assert match(lib, "stashed").name == "stash"
    assert match(lib, "(blocks!)").name == "widgets"


def test_clip_rotation_persists(tmp_path):
    lib = make_library(tmp_path / "lib", tmp_path / "state.json")
    concept = match(lib, "widget")
    first = lib.next_clip(concept).name
    second = lib.next_clip(concept).name
    assert {first, second} == {"a.mp4", "b.mp4"}
    # A fresh library instance continues the rotation from disk state.
    again = BRollLibrary(root=tmp_path / "lib", state_path=tmp_path / "state.json")
    assert again.next_clip(match(again, "widget")).name == first


def test_plan_respects_pacing(tmp_path):
    lib = make_library(tmp_path / "lib", tmp_path / "state.json")
    segments = words(
        ("widget", 0.5),  # too early (start_after)
        ("widget", 2.0),  # insert 1
        ("stash", 3.0),  # too close (min_gap)
        ("blocks", 9.0),  # insert 2
    )
    inserts = plan_inserts(segments, lib, clip_seconds=2.0, min_gap=4.0, start_after=1.5)
    assert [i["start"] for i in inserts] == [2.0, 9.0]
    assert inserts[0]["concept"] == "widgets"


def test_plan_caps_inserts(tmp_path):
    lib = make_library(tmp_path / "lib", tmp_path / "state.json")
    segments = words(*[("widget", 2.0 + i * 10) for i in range(10)])
    inserts = plan_inserts(segments, lib, max_inserts=3)
    assert len(inserts) == 3


def test_empty_library_plans_nothing(tmp_path):
    lib = BRollLibrary(root=tmp_path / "nope", state_path=tmp_path / "state.json")
    assert plan_inserts(words(("widget", 5.0)), lib) == []


def test_lexicon_matches_all_languages(tmp_path):
    """Built-in concepts (folder named in canonical English) fire on the
    same word in any of the four supported languages."""
    root = tmp_path / "lib"
    dog = root / "dog"
    dog.mkdir(parents=True)
    (dog / "clip.mp4").touch()
    lib = BRollLibrary(root=root, state_path=tmp_path / "state.json")

    assert match(lib, "dog").name == "dog"
    assert match(lib, "собакой").name == "dog"  # RU, inflected
    assert match(lib, "Hund").name == "dog"  # DE
    assert match(lib, "chien").name == "dog"  # FR
    assert lib.match_word("cat") is None


def test_color_concepts_match(tmp_path):
    root = tmp_path / "lib"
    green = root / "green"
    green.mkdir(parents=True)
    (green / "clip.mp4").touch()
    lib = BRollLibrary(root=root, state_path=tmp_path / "state.json")

    assert match(lib, "зелёный").name == "green"
    assert match(lib, "green").name == "green"
    assert match(lib, "vert").name == "green"


def test_legacy_folder_migrates(tmp_path):
    """Folders from an earlier Piko version (Russian concept names) are
    renamed on-disk to their canonical English concept on first scan."""
    root = tmp_path / "lib"
    legacy = root / "собака"
    legacy.mkdir(parents=True)
    (legacy / "clip.mp4").touch()

    lib = BRollLibrary(root=root, state_path=tmp_path / "state.json")

    assert [c.name for c in lib.concepts] == ["dog"]
    assert (root / "dog").is_dir()
    assert not legacy.exists()
    assert match(lib, "dog").name == "dog"


def test_legacy_folder_migration_merges_into_existing(tmp_path):
    """If both the legacy and canonical folder exist, clips merge and no
    data is lost."""
    root = tmp_path / "lib"
    legacy = root / "собака"
    legacy.mkdir(parents=True)
    (legacy / "old.mp4").touch()
    canonical = root / "dog"
    canonical.mkdir()
    (canonical / "new.mp4").touch()

    lib = BRollLibrary(root=root, state_path=tmp_path / "state.json")

    assert [c.name for c in lib.concepts] == ["dog"]
    assert not legacy.exists()
    assert {p.name for p in (root / "dog").iterdir()} == {"old.mp4", "new.mp4"}


def test_starter_pack_manifest_sane():
    from piko.commands.broll_pack import STARTER_PACK

    slugs = [e["slug"] for e in STARTER_PACK]
    assert len(slugs) == len(set(slugs))
    for entry in STARTER_PACK:
        assert entry["url"].startswith(
            ("https://upload.wikimedia.org/", "https://images-assets.nasa.gov/")
        )
        assert entry["concept"] and entry["aliases"]
        assert "share" not in entry["license"].lower()  # no share-alike terms
        assert entry["license"].split()[0] in ("CC0", "Public", "CC")
        start, duration = entry["trim"]
        assert start >= 0 and 0 < duration <= 10
