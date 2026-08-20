"""Tests for the pre-flight memory guardrail (core/memory.py)."""

import pytest

from piko.core import memory
from piko.core.memory import (
    AUDIO_MB_PER_HOUR,
    InsufficientMemoryError,
    check_memory,
    estimate_transcribe_peak_mb,
    parse_vm_stat,
    requires_memory,
)

VM_STAT_SAMPLE = """\
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              250665.
Pages active:                            876986.
Pages inactive:                          764124.
Pages speculative:                       132393.
Pages throttled:                              0.
Pages wired down:                        240276.
Pages purgeable:                         109089.
"Translation faults":                 179420359.
"""


def test_parse_vm_stat_free_plus_inactive():
    available = parse_vm_stat(VM_STAT_SAMPLE)
    assert available == (250665 + 764124) * 16384


def test_parse_vm_stat_garbage_returns_none():
    assert parse_vm_stat("") is None
    assert parse_vm_stat("page size of 16384 bytes\nno page counts here") is None


def test_estimate_grows_with_duration():
    model = "mlx-community/whisper-tiny"
    short = estimate_transcribe_peak_mb(model, 60.0)
    long = estimate_transcribe_peak_mb(model, 10 * 3600.0)
    assert long - short == pytest.approx(10 * AUDIO_MB_PER_HOUR, abs=AUDIO_MB_PER_HOUR / 60)


def test_estimate_unknown_model_uses_default():
    assert estimate_transcribe_peak_mb("some/custom-model", 0.0) == memory.DEFAULT_MODEL_PEAK_MB


def test_check_raises_when_memory_is_low(monkeypatch):
    monkeypatch.setattr(memory, "available_memory_mb", lambda: 1000)
    with pytest.raises(InsufficientMemoryError, match="pick a smaller model"):
        check_memory(4000, "whisper-large-v3-mlx-8bit + 60 min of audio")


def test_check_passes_when_memory_is_plenty(monkeypatch):
    monkeypatch.setattr(memory, "available_memory_mb", lambda: 64 * 1024)
    check_memory(4000, "whisper-large-v3-mlx-8bit + 60 min of audio")


def test_check_fails_open_when_unreadable(monkeypatch):
    monkeypatch.setattr(memory, "available_memory_mb", lambda: None)
    check_memory(10**9, "an absurdly large model")


def test_decorator_blocks_before_calling(monkeypatch):
    monkeypatch.setattr(memory, "available_memory_mb", lambda: 1000)
    calls = []

    @requires_memory(lambda size: (size * 100, f"model of size {size}"))
    def load_model(size):
        calls.append(size)
        return "loaded"

    with pytest.raises(InsufficientMemoryError):
        load_model(50)  # 5000 MB > 1000 MB available
    assert calls == []  # the wrapped function never ran


def test_decorator_passes_through(monkeypatch):
    monkeypatch.setattr(memory, "available_memory_mb", lambda: 64 * 1024)

    @requires_memory(lambda size: (size * 100, f"model of size {size}"))
    def load_model(size):
        return f"loaded {size}"

    assert load_model(50) == "loaded 50"
