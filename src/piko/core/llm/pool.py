"""Process-wide warm model, so the load cost is paid once per process.

Loading the balanced tier costs ~2 s and 2.2 GB of resident weights (4.7 GB at
the peak of a summary — registry.py has the measured table). That is bearable
once, and unbearable per transcript chunk — so the session outlives the command
that created it and the next command reuses it.

This only pays off when the backend runs in persistent mode (see main.py):
under the one-shot protocol the process exits and takes the weights with it.

Thread-safety: `acquire` is serialized by a lock so a background `warm_async`
and a foreground request cannot both load. Generation itself is *not*
parallelized — an `LLMSession` wraps one decode loop, and callers share one.
"""

from __future__ import annotations

import contextlib
import os
import threading
import time
from collections.abc import Iterator

from .registry import resolve_tier
from .session import LLMSession, open_session

# How long a resident model may sit unused before it gives the memory back.
#
# Holding gigabytes of weights for a conversation somebody walked away from an
# hour ago is not "warm", it is a leak with a good excuse. Ten minutes is
# longer than any pause inside a working session and shorter than a lunch
# break; the reload costs the same two seconds it cost the first time.
IDLE_RELEASE_SECONDS = float(os.environ.get("PIKO_LLM_IDLE_SECONDS", 600))

_lock = threading.RLock()
# Anything that actually runs the model holds this.
#
# Separate from `_lock`, which guards the *bookkeeping* — which model is
# resident, when it was last used — and is taken briefly by a status poll every
# few seconds. Generation cannot hold that one for the length of an answer
# without stalling the sidebar, and it cannot go unguarded either: two threads
# evaluating one MLX graph is a SIGSEGV, not a race you get a traceback for.
#
# Nothing needed this while every command was its own process. A resident
# process is what put a background warmup and a foreground question on the same
# weights, and the crash was immediate: warm the model, ask a question 200 ms
# later, exit -11.
_gpu = threading.RLock()
_session: LLMSession | None = None
_key: str | None = None
_warming: threading.Thread | None = None
_error: str | None = None
_last_used: float = 0.0
_busy = 0
_sweeper: threading.Thread | None = None


def session_key(params: dict | None) -> str:
    """Identity of a configuration: two params that differ here need a reload.

    The tier is resolved before keying, so an omitted tier and the tier it
    resolves to are the same session. Keying on the raw value would make a
    warmup for "balanced" look like a miss to a request that just left the
    field empty — and reload 4.4 GB for nothing.
    """
    params = params or {}
    provider = params.get("provider") or "mlx"
    if provider == "mlx":
        return f"mlx:{resolve_tier(params.get('tier')).tier}"
    return f"{provider}:{params.get('base_url') or ''}:{params.get('model') or ''}"


def acquire(params: dict | None = None) -> LLMSession:
    """The warm session for `params`, loading it if needed.

    A request for a different model closes the current one first: two large
    models resident at once is exactly the case PRODUCT.md's 16 GB bar cannot
    afford.
    """
    global _session, _key, _error

    key = session_key(params)
    with _lock:
        if _session is not None and _key == key:
            return _session
        if _session is not None:
            release()
        _error = None
        session = open_session(params)
        _session, _key = session, key
        _touch()
        _start_sweeper()
        return session


def warm_async(params: dict | None = None) -> threading.Thread:
    """Start loading in the background and return immediately.

    Intended to overlap with transcription: by the time the user has a
    transcript, the summarizer is ready. Failures are captured in `status()`
    rather than raised — a warmup that fails must never break the run that
    triggered it, and the real request will surface the same error properly.
    """
    global _warming, _error

    def _load() -> None:
        global _error
        try:
            session = acquire(params)
            warmup = getattr(session, "warmup", None)
            if callable(warmup):
                # Inside `in_use`, because a warmup is a forward pass like any
                # other and the foreground must queue behind it rather than
                # evaluate alongside it.
                with in_use():
                    warmup()
        except Exception as e:  # noqa: BLE001 — recorded, re-raised on real use
            _error = f"{type(e).__name__}: {e}"

    with _lock:
        if _warming is not None and _warming.is_alive():
            return _warming
        _warming = threading.Thread(target=_load, name="llm-warmup", daemon=True)
        _warming.start()
        return _warming


def _touch() -> None:
    global _last_used
    _last_used = time.monotonic()


@contextlib.contextmanager
def in_use() -> Iterator[None]:
    """Mark the model as working.

    Two jobs. The busy count stops the idle sweeper from freeing weights out
    from under a summary that has been map-reducing for four minutes — `acquire`
    is called once at the start of that run, so a timer keyed on acquisition
    alone would eventually pull the rug. And holding `_gpu` for the whole scope
    is what serialises the model itself, so a question asked while the warmup is
    still running waits for it instead of crashing the process.

    Deliberately *not* trimming MLX's buffer pool here. That pool is the reuse:
    freed buffers stay around so the next allocation does not go back to the
    allocator, and emptying it between requests spends the next prompt's first
    milliseconds to make an idle number look smaller. The memory that matters is
    given back by the idle sweeper and by Eject, both of which drop the weights
    themselves — which is a real answer rather than a cosmetic one.
    """
    global _busy

    with _lock:
        _busy += 1
    try:
        with _gpu:
            yield
    finally:
        with _lock:
            _busy -= 1
            _touch()


def trim() -> None:
    """Empty MLX's buffer pool. Only on release, where the point is to leave."""
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:  # noqa: BLE001,S110 — a non-MLX provider has nothing to trim
        return


def _start_sweeper() -> None:
    """One daemon thread, watching for a model nobody is using any more."""
    global _sweeper

    if IDLE_RELEASE_SECONDS <= 0:
        return
    if _sweeper is not None and _sweeper.is_alive():
        return

    def _sweep() -> None:
        while True:
            time.sleep(5)
            with _lock:
                if _session is None:
                    return
                idle = _busy == 0 and time.monotonic() - _last_used > IDLE_RELEASE_SECONDS
            if idle:
                release()
                return

    _sweeper = threading.Thread(target=_sweep, name="llm-idle-sweeper", daemon=True)
    _sweeper.start()


def memory() -> dict:
    """What this process is actually holding, in bytes.

    Reported rather than estimated: "the balanced tier is about 4.4 GB" is a
    number from a benchmark, and the one worth showing a user is the one their
    machine has right now.
    """
    try:
        import mlx.core as mx

        return {
            "active_bytes": int(mx.get_active_memory()),
            "cache_bytes": int(mx.get_cache_memory()),
        }
    except Exception:  # noqa: BLE001 — no MLX, nothing to report
        return {}


def is_warm(params: dict | None = None) -> bool:
    with _lock:
        return _session is not None and _key == session_key(params)


def status(params: dict | None = None) -> dict:
    """Snapshot for the `llm_status` command."""
    with _lock:
        loading = _warming is not None and _warming.is_alive()
        idle_for = time.monotonic() - _last_used if _session is not None else 0.0
        snapshot = {
            "loaded": _session is not None,
            "loading": loading,
            "model_key": _key,
            "matches_request": _session is not None and _key == session_key(params),
            "warmup_error": _error,
            "idle_seconds": round(idle_for, 1),
            "releases_after": IDLE_RELEASE_SECONDS,
        }
    snapshot.update(memory())
    return snapshot


def release() -> None:
    """Drop the model and free its memory. Safe to call when nothing is loaded."""
    global _session, _key

    with _lock:
        if _session is not None:
            _session.close()
        _session = None
        _key = None
    trim()
