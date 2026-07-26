"""Process-wide warm model, so the load cost is paid once per process.

Loading the balanced tier costs ~2 s and ~4.4 GB (bench/llm). That is bearable
once, and unbearable per transcript chunk — so the session outlives the command
that created it and the next command reuses it.

This only pays off when the backend runs in persistent mode (see main.py):
under the one-shot protocol the process exits and takes the weights with it.

Thread-safety: `acquire` is serialized by a lock so a background `warm_async`
and a foreground request cannot both load. Generation itself is *not*
parallelized — an `LLMSession` wraps one decode loop, and callers share one.
"""

from __future__ import annotations

import threading

from .registry import resolve_tier
from .session import LLMSession, open_session

_lock = threading.RLock()
_session: LLMSession | None = None
_key: str | None = None
_warming: threading.Thread | None = None
_error: str | None = None


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
                warmup()
        except Exception as e:  # noqa: BLE001 — recorded, re-raised on real use
            _error = f"{type(e).__name__}: {e}"

    with _lock:
        if _warming is not None and _warming.is_alive():
            return _warming
        _warming = threading.Thread(target=_load, name="llm-warmup", daemon=True)
        _warming.start()
        return _warming


def is_warm(params: dict | None = None) -> bool:
    with _lock:
        return _session is not None and _key == session_key(params)


def status(params: dict | None = None) -> dict:
    """Snapshot for the `llm_status` command."""
    with _lock:
        loading = _warming is not None and _warming.is_alive()
        return {
            "loaded": _session is not None,
            "loading": loading,
            "model_key": _key,
            "matches_request": _session is not None and _key == session_key(params),
            "warmup_error": _error,
        }


def release() -> None:
    """Drop the model and free its memory. Safe to call when nothing is loaded."""
    global _session, _key

    with _lock:
        if _session is not None:
            _session.close()
        _session = None
        _key = None
