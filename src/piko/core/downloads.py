"""Model downloads that report bytes, percent and speed.

`snapshot_download` is otherwise silent for minutes at a time — bearable for a
1.8 GB model, not for the 12 GB quality tier, where a bar that only says
"Downloading..." is indistinguishable from one that has hung.

Progress is measured by **watching the cache directory grow**, not by hooking
tqdm. `snapshot_download` only renders one outer "Fetching N files" bar and
creates no per-file byte bars, so a `tqdm_class` hook reports nothing at all
(measured: a 652 MB download produced zero byte events). Bytes on disk are also
the honest number — they survive retries, resumed `.incomplete` blobs and
whatever the library changes next.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

# How often progress is sampled. The frontend redraws a bar; it does not need
# one event per network chunk.
POLL_INTERVAL_S = 0.4
# Speed is averaged over this window, so one slow chunk does not read as a stall.
SPEED_WINDOW_S = 3.0

# Once the bytes stop growing this long, the transfer is done and the library
# is hashing blobs and moving them into place. On a 652 MB model that tail was
# 14 of 18 seconds — long enough to read as a hang unless it is named.
FINALIZE_AFTER_S = 1.5
# Below this the transfer is genuinely still running and a pause is a stall,
# not verification.
FINALIZE_ABOVE_PERCENT = 95.0


@dataclass(frozen=True, slots=True)
class Progress:
    """One sample of a download in flight."""

    percent: float
    downloaded: int
    bytes_per_second: float
    finalizing: bool = False


ProgressCallback = Callable[[Progress], None]


def repo_size_bytes(repo_id: str) -> int:
    """Total size of a repo's files, or 0 when the Hub cannot be reached."""
    from huggingface_hub import HfApi

    try:
        info = HfApi().model_info(repo_id, files_metadata=True)
    except Exception:  # noqa: BLE001 — a missing total only costs the percentage
        return 0
    return sum(sibling.size or 0 for sibling in (info.siblings or []))


def _cache_folder(repo_id: str) -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE
    from huggingface_hub.file_download import repo_folder_name

    return Path(HF_HUB_CACHE) / repo_folder_name(repo_id=repo_id, repo_type="model")


def _bytes_on_disk(folder: Path) -> int:
    """Size of the repo's blobs, counting partially fetched `.incomplete` files."""
    blobs = folder / "blobs"
    if not blobs.is_dir():
        return 0
    total = 0
    for path in blobs.iterdir():
        try:
            total += path.stat().st_size
        except OSError:
            continue  # vanished mid-scan: a blob being renamed into place
    return total


class _Watcher(threading.Thread):
    """Polls the cache folder and reports growth until told to stop."""

    def __init__(self, repo_id: str, total: int, on_progress: ProgressCallback) -> None:
        super().__init__(name=f"download-watch-{repo_id}", daemon=True)
        self.folder = _cache_folder(repo_id)
        self.total = total
        self.on_progress = on_progress
        self._stop = threading.Event()
        # Anything already cached is not part of this download's progress.
        self._baseline = _bytes_on_disk(self.folder)

    def run(self) -> None:
        samples: list[tuple[float, int]] = []
        last_change = time.monotonic()
        last_done = 0
        finalizing = False
        while not self._stop.is_set():
            self._stop.wait(POLL_INTERVAL_S)
            now = time.monotonic()
            done = max(0, _bytes_on_disk(self.folder) - self._baseline)
            if done == 0:
                continue
            if done != last_done:
                last_done, last_change = done, now

            samples.append((now, done))
            cutoff = now - SPEED_WINDOW_S
            while len(samples) > 2 and samples[0][0] < cutoff:
                samples.pop(0)

            speed = 0.0
            if len(samples) >= 2:
                elapsed = samples[-1][0] - samples[0][0]
                if elapsed > 0:
                    speed = (samples[-1][1] - samples[0][1]) / elapsed

            remaining = max(1, self.total - self._baseline)
            # Capped at 99: the completion event is what shows 100, and the
            # total is an estimate whenever part of the repo was already there.
            percent = min(99.0, 100.0 * done / remaining) if self.total else 0.0
            # Latched once the transfer is essentially over: stray blobs keep
            # landing while the library verifies, and a label flickering
            # between "downloading" and "verifying" is worse than either.
            if now - last_change > FINALIZE_AFTER_S and percent >= FINALIZE_ABOVE_PERCENT:
                finalizing = True
            self.on_progress(
                Progress(
                    percent=percent,
                    downloaded=done,
                    bytes_per_second=0.0 if finalizing else speed,
                    finalizing=finalizing,
                )
            )

    def stop(self) -> None:
        self._stop.set()


def download_model(repo_id: str, on_progress: ProgressCallback) -> str:
    """Download `repo_id`, reporting progress until it completes."""
    from huggingface_hub import snapshot_download

    watcher = _Watcher(repo_id, repo_size_bytes(repo_id), on_progress)
    watcher.start()
    try:
        return str(snapshot_download(repo_id=repo_id))
    finally:
        watcher.stop()
        watcher.join(timeout=2)


def format_bytes(count: float) -> str:
    """1536000000 -> '1.5 GB'. Decimal units, matching how model sizes are quoted."""
    for unit, size in (("GB", 1e9), ("MB", 1e6), ("KB", 1e3)):
        if count >= size:
            return f"{count / size:.1f} {unit}"
    return f"{int(count)} B"
