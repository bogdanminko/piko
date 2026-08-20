"""Parent-process watchdog.

Each backend process is a child of the Swift app. If the app dies (including
SIGKILL, where it cannot clean up), the backend would be reparented to
launchpd and keep transcribing with gigabytes of RAM. This daemon thread
polls the parent pid and hard-exits the whole process group — taking any
running ffmpeg child with it — the moment the parent is gone.
"""

from __future__ import annotations

import os
import sys
import threading
import time

_POLL_SECONDS = 2.0


def _watch() -> None:
    while True:
        time.sleep(_POLL_SECONDS)
        if os.getppid() == 1:  # reparented to launchd — the app is gone
            sys.stderr.write("parent process died, exiting\n")
            sys.stderr.flush()
            # Hard exit without interpreter teardown. A running ffmpeg
            # child then dies on its own: its progress pipe loses its
            # reader and the next write raises SIGPIPE. Never signal the
            # whole process group here — in shell contexts it can contain
            # an innocent live ancestor.
            os._exit(1)


def start() -> None:
    """Start the watchdog; harmless for short-lived CLI invocations."""
    threading.Thread(target=_watch, name="parent-watchdog", daemon=True).start()
