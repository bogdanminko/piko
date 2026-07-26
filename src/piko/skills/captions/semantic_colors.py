"""Semantic word coloring: words that name a color (or a strongly
color-associated object) get painted that color and receive a matching
emoji — independent of keyword detection. EN + RU.

Matching mirrors emoji_mapper: exact form match first, then stem
startswith for stems of 4+ chars (covers Russian inflection).
"""

from __future__ import annotations

# (match_terms, hex_color, emoji)
# Terms of 4+ chars match as prefixes ("зелен" -> зелёный/зелёного/...),
# shorter ones must match exactly.
_ENTRIES: list[tuple[tuple[str, ...], str, str]] = [
    # --- Colors: EN + RU ---
    (("red", "красн"), "#FF3B30", "\U0001f534"),  # 🔴
    (("green", "зелен", "зелён"), "#34C759", "\U0001f7e2"),  # 🟢
    (
        ("blue", "синий", "синяя", "синее", "синие", "синего", "синему", "синим", "синих", "синем"),
        "#0A84FF",
        "\U0001f535",
    ),  # 🔵
    (("голуб",), "#5AC8FA", "\U0001f535"),
    (("yellow", "желт", "жёлт"), "#FFD60A", "\U0001f7e1"),  # 🟡
    (("orange", "оранжев"), "#FF9500", "\U0001f7e0"),  # 🟠
    (("purple", "violet", "фиолетов", "пурпурн"), "#BF5AF2", "\U0001f7e3"),  # 🟣
    (("pink", "розов"), "#FF5AC8", "\U0001fa77"),  # 🩷
    (("brown", "коричнев"), "#A2845E", "\U0001f7e4"),  # 🟤
    (("black", "черн", "чёрн"), "#98989D", "⚫"),  # ⚫ (gray tint for visibility)
    (
        ("white", "белый", "белая", "белое", "белые", "белого", "белой", "белым", "белых"),
        "#FFFFFF",
        "⚪",
    ),  # ⚪
    (
        ("gray", "grey", "серый", "серая", "серое", "серые", "серого", "серой", "серым", "серых"),
        "#8E8E93",
        "⚫",
    ),
    (("gold", "golden", "золот"), "#FFD700", "\U0001f947"),  # 🥇
    (("silver", "серебр"), "#C7C7CC", "\U0001f948"),  # 🥈
    # --- Color-associated objects ---
    (("fire", "flame", "огонь", "огня", "огне", "огнём", "пламя"), "#FF6B35", "\U0001f525"),  # 🔥
    (("water", "вода", "воды", "воду", "воде", "водой"), "#339CFF", "\U0001f4a7"),  # 💧
    (("sun", "sunny", "солнц"), "#FFD60A", "☀️"),  # ☀️
    (("ice", "frozen", "холод", "лёд", "льда", "льду", "мороз"), "#7DD8FF", "\U0001f9ca"),  # 🧊
    (("love", "любовь", "любви", "любят", "люблю"), "#FF3B5C", "❤️"),  # ❤️
    (
        ("money", "cash", "деньги", "денег", "деньгам", "бабки", "бабок"),
        "#34C759",
        "\U0001f4b0",
    ),  # 💰
    # --- Growth / decline (finance-talk accent) ---
    (
        ("grow", "growth", "growing", "profit", "рост", "раст", "выросл", "прибыл"),
        "#34C759",
        "\U0001f4c8",
    ),  # 📈
    (
        ("crash", "drop", "loss", "падени", "упал", "упало", "упали", "обвал", "убыт"),
        "#FF3B30",
        "\U0001f4c9",
    ),  # 📉
]

# Build lookup tables once
_EXACT: dict[str, tuple[str, str]] = {}
_STEMS: list[tuple[str, str, str]] = []
for terms, color, emoji in _ENTRIES:
    for t in terms:
        _EXACT[t] = (color, emoji)
        if len(t) >= 4:
            _STEMS.append((t, color, emoji))


def get_semantic(word: str) -> tuple[str, str] | None:
    """Return (hex_color, emoji) for a word, or None."""
    clean = word.strip().strip(".,!?;:\"'()-").lower()
    if not clean:
        return None

    if clean in _EXACT:
        return _EXACT[clean]

    for stem, color, emoji in _STEMS:
        if clean.startswith(stem):
            return (color, emoji)

    return None
