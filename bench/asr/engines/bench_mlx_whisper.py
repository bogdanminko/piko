"""mlx-whisper benchmark runner. Runs inside the project venv (has mlx-whisper).

Usage: python bench_mlx_whisper.py <audio.wav> <model_repo> [--word-timestamps] [--lang xx]
Emits one JSON line to stdout.
"""

import argparse
import json
import sys
import time


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("model")
    parser.add_argument("--word-timestamps", action="store_true")
    parser.add_argument("--lang", default=None)
    args = parser.parse_args()

    import mlx.core as mx
    import mlx_whisper
    from mlx_whisper.transcribe import ModelHolder

    t0 = time.perf_counter()
    ModelHolder.get_model(args.model, mx.float16)
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    result = mlx_whisper.transcribe(
        args.audio,
        path_or_hf_repo=args.model,
        word_timestamps=args.word_timestamps,
        language=args.lang,
        verbose=None,
    )
    transcribe_s = time.perf_counter() - t1

    json.dump(
        {
            "engine": "mlx-whisper" + ("+wordts" if args.word_timestamps else ""),
            "model": args.model,
            "load_s": load_s,
            "transcribe_s": transcribe_s,
            "text": result["text"],
            "n_segments": len(result.get("segments", [])),
            "language": result.get("language"),
        },
        sys.stdout,
        ensure_ascii=False,
    )
    print()


if __name__ == "__main__":
    main()
