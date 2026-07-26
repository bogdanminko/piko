# /// script
# requires-python = ">=3.11"
# dependencies = ["parakeet-mlx"]
# ///
"""parakeet-mlx benchmark runner. Run with: uv run --script bench_parakeet_mlx.py <audio.wav> [model_repo]

Emits one JSON line to stdout.
"""

import json
import sys
import time


def main() -> None:
    audio = sys.argv[1]
    model_repo = sys.argv[2] if len(sys.argv) > 2 else "mlx-community/parakeet-tdt-0.6b-v3"

    from parakeet_mlx import from_pretrained

    t0 = time.perf_counter()
    model = from_pretrained(model_repo)
    load_s = time.perf_counter() - t0

    # Chunking is required for long audio: a single pass OOMs Metal (~32 GB buffer
    # for 30 min). 120 s chunks + 15 s overlap, same settings as the mlx-audio runner.
    t1 = time.perf_counter()
    result = model.transcribe(audio, chunk_duration=120.0, overlap_duration=15.0)
    transcribe_s = time.perf_counter() - t1

    json.dump(
        {
            "engine": "parakeet-mlx",
            "model": model_repo,
            "load_s": load_s,
            "transcribe_s": transcribe_s,
            "text": result.text,
            "n_segments": len(result.sentences),
        },
        sys.stdout,
        ensure_ascii=False,
    )
    print()


if __name__ == "__main__":
    main()
