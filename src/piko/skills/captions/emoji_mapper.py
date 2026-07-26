"""Contextual emoji mapping for keywords."""

from __future__ import annotations

EMOJI_MAP: dict[str, str] = {
    # Money / Business
    "money": "\U0001f4b0", "cash": "\U0001f4b5", "dollar": "\U0001f4b5",
    "revenue": "\U0001f4c8", "profit": "\U0001f4b0", "invest": "\U0001f4c8",
    "business": "\U0001f4bc", "rich": "\U0001f4b0", "expensive": "\U0001f4b8",
    "cheap": "\U0001f4b8", "price": "\U0001f4b2", "pay": "\U0001f4b3",
    # Fire / Energy
    "fire": "\U0001f525", "hot": "\U0001f525", "amazing": "\U0001f525",
    "incredible": "\U0001f525", "epic": "\U0001f525", "insane": "\U0001f4a5",
    "crazy": "\U0001f92f", "awesome": "\U0001f525", "powerful": "\u26a1",
    "energy": "\u26a1", "electric": "\u26a1", "explosive": "\U0001f4a5",
    # Victory / Success
    "win": "\U0001f3c6", "champion": "\U0001f3c6", "best": "\U0001f3c6",
    "first": "\U0001f947", "top": "\U0001f451", "success": "\U0001f3c6",
    "winner": "\U0001f3c6", "greatest": "\U0001f451", "legend": "\U0001f451",
    "perfect": "\U0001f44c", "master": "\U0001f3c6",
    # Failure / Pain
    "fail": "\U0001f480", "lose": "\U0001f480", "worst": "\U0001f480",
    "terrible": "\U0001f480", "broke": "\U0001f4a9", "dead": "\U0001f480",
    "wrong": "\u274c", "mistake": "\u274c", "bad": "\U0001f44e",
    "disaster": "\U0001f4a5", "destroy": "\U0001f4a5",
    # Scale / Numbers
    "million": "\U0001f92f", "billion": "\U0001f92f", "thousand": "\U0001f4ab",
    "hundred": "\U0001f4ab", "massive": "\U0001f680", "huge": "\U0001f680",
    "giant": "\U0001f680", "tiny": "\U0001f41c",
    # Food
    "eat": "\U0001f37d\ufe0f", "food": "\U0001f354", "cook": "\U0001f373",
    "restaurant": "\U0001f37d\ufe0f", "pizza": "\U0001f355", "delicious": "\U0001f60b",
    # Body / Health
    "gym": "\U0001f4aa", "muscle": "\U0001f4aa", "strong": "\U0001f4aa",
    "workout": "\U0001f3cb\ufe0f", "health": "\u2764\ufe0f", "fit": "\U0001f4aa",
    # Secrets / Hacks
    "secret": "\U0001f92b", "hack": "\U0001f4a1", "trick": "\U0001f4a1",
    "tip": "\U0001f4a1", "hidden": "\U0001f92b", "reveal": "\U0001f440",
    "discover": "\U0001f50d", "unlock": "\U0001f511",
    # Time
    "fast": "\u26a1", "quick": "\u26a1", "slow": "\U0001f422",
    "wait": "\u23f0", "time": "\u23f0", "instant": "\u26a1",
    # Emotions
    "happy": "\U0001f60a", "sad": "\U0001f622", "angry": "\U0001f621",
    "love": "\u2764\ufe0f", "hate": "\U0001f624", "fear": "\U0001f631",
    "surprise": "\U0001f632", "laugh": "\U0001f602", "cry": "\U0001f622",
    "shock": "\U0001f631", "wow": "\U0001f632",
    # Russian
    "\u0434\u0435\u043d\u044c\u0433\u0438": "\U0001f4b0",
    "\u043e\u0433\u043e\u043d\u044c": "\U0001f525",
    "\u043f\u043e\u0431\u0435\u0434\u0430": "\U0001f3c6",
    "\u043f\u0440\u043e\u0432\u0430\u043b": "\U0001f480",
    "\u043b\u044e\u0431\u043e\u0432\u044c": "\u2764\ufe0f",
    "\u043a\u0440\u0443\u0442\u043e": "\U0001f525",
    "\u0432\u0430\u0443": "\U0001f632",
    "\u043a\u043b\u0430\u0441\u0441": "\U0001f4aa",
    "\u0441\u0435\u043a\u0440\u0435\u0442": "\U0001f92b",
    "\u043c\u0438\u043b\u043b\u0438\u043e\u043d": "\U0001f92f",
    "\u0442\u044b\u0441\u044f\u0447\u0430": "\U0001f4ab",
    "\u043f\u0435\u0440\u0432\u044b\u0439": "\U0001f947",
    "\u043b\u0443\u0447\u0448\u0438\u0439": "\U0001f3c6",
    "\u0445\u0443\u0434\u0448\u0438\u0439": "\U0001f480",
    "\u0431\u044b\u0441\u0442\u0440\u043e": "\u26a1",
    "\u0441\u0438\u043b\u0430": "\U0001f4aa",
    "\u0441\u0442\u0440\u0430\u0448\u043d\u043e": "\U0001f631",
    "\u0441\u043c\u0435\u0448\u043d\u043e": "\U0001f602",
    "\u0443\u0436\u0430\u0441": "\U0001f480",
    "\u043a\u0440\u0430\u0441\u0438\u0432\u043e": "\u2728",
    "\u0431\u0435\u0437\u0443\u043c\u043d\u044b\u0439": "\U0001f92f",
    "\u043d\u0435\u0432\u0435\u0440\u043e\u044f\u0442\u043d\u043e": "\U0001f525",
    "\u043f\u043e\u0442\u0440\u044f\u0441\u0430\u044e\u0449\u0435": "\U0001f525",
}


def get_emoji(word: str) -> str | None:
    """Return emoji for a word, or None if no mapping found."""
    clean = word.strip().strip(".,!?;:\"'()-").lower()

    # Exact match
    if clean in EMOJI_MAP:
        return EMOJI_MAP[clean]

    # Stem match (word starts with a known key)
    for key, emoji in EMOJI_MAP.items():
        if len(key) >= 4 and clean.startswith(key):
            return emoji

    return None
