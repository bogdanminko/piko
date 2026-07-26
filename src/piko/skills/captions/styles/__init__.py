"""Subtitle style registry."""

from __future__ import annotations

from .mrbeast import MrBeastStyle
from .hormozi import HormoziStyle
from .tiktok import TikTokStyle
from .karaoke import KaraokeStyle
from .minimal import MinimalStyle

STYLES: dict[str, type] = {
    "mrbeast": MrBeastStyle,
    "hormozi": HormoziStyle,
    "tiktok": TikTokStyle,
    "karaoke": KaraokeStyle,
    "minimal": MinimalStyle,
}
