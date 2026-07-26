"""Subtitle style registry."""

from __future__ import annotations

from .hormozi import HormoziStyle
from .karaoke import KaraokeStyle
from .minimal import MinimalStyle
from .mrbeast import MrBeastStyle
from .tiktok import TikTokStyle

STYLES: dict[str, type] = {
    "mrbeast": MrBeastStyle,
    "hormozi": HormoziStyle,
    "tiktok": TikTokStyle,
    "karaoke": KaraokeStyle,
    "minimal": MinimalStyle,
}
