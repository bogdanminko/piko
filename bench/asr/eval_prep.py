# /// script
# requires-python = ">=3.11"
# dependencies = ["datasets>=3.2", "soundfile", "numpy", "scipy"]
# ///
"""Materialize an eval bench cell into bench/audio/eval/<name>/:
16 kHz mono WAVs + refs.jsonl ({id, text, duration_s} per line).

Usage: uv run --script bench/eval_prep.py <fleurs_ru|fleurs_en|golos_farfield|ami> [--minutes 30]

Fixed seed / deterministic order: we take the first N minutes of the (already
shuffled by the dataset authors) test split — reproducible without a local seed.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

BENCH = Path(__file__).parent

SPECS = {
    "fleurs_ru": dict(repo="google/fleurs", config="ru_ru", split="test", text_col="transcription"),
    "fleurs_en": dict(repo="google/fleurs", config="en_us", split="test", text_col="transcription"),
    "fleurs_de": dict(repo="google/fleurs", config="de_de", split="test", text_col="transcription"),
    "fleurs_fr": dict(repo="google/fleurs", config="fr_fr", split="test", text_col="transcription"),
    "golos_farfield": dict(
        repo="bond005/sberdevices_golos_100h_farfield",
        config=None,
        split="test",
        text_col="transcription",
    ),
    "ami": dict(repo="edinburghcstr/ami", config="ihm", split="test", text_col="text"),
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bench", choices=SPECS)
    parser.add_argument("--minutes", type=float, default=30.0)
    args = parser.parse_args()
    spec = SPECS[args.bench]

    from datasets import Audio, load_dataset

    out_dir = BENCH / "audio" / "eval" / args.bench
    out_dir.mkdir(parents=True, exist_ok=True)

    ds = load_dataset(spec["repo"], spec["config"], split=spec["split"], streaming=True)
    # decode=False: raw bytes, decoded below with soundfile — avoids the
    # torchcodec/torch dependency that datasets>=4 wants for audio decoding.
    ds = ds.cast_column("audio", Audio(decode=False))

    import io

    from scipy.signal import resample_poly

    total_s = 0.0
    n = 0
    refs = []
    budget_s = args.minutes * 60
    for ex in ds:
        audio = ex["audio"]
        raw = audio["bytes"]
        if raw is None:
            with open(audio["path"], "rb") as fh:
                raw = fh.read()
        arr, sr = sf.read(io.BytesIO(raw), dtype="float32", always_2d=False)
        if arr.ndim > 1:
            arr = arr.mean(axis=1)
        if sr != 16000:
            arr = resample_poly(arr, 16000, sr).astype(np.float32)
        dur = len(arr) / 16000
        text = (ex.get(spec["text_col"]) or "").strip()
        if not text or dur < 0.3:
            continue
        uid = f"{args.bench}-{n:05d}"
        sf.write(out_dir / f"{uid}.wav", arr, 16000, subtype="PCM_16")
        refs.append({"id": uid, "text": text, "duration_s": round(dur, 3)})
        total_s += dur
        n += 1
        if total_s >= budget_s:
            break

    with (out_dir / "refs.jsonl").open("w") as f:
        for r in refs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(
        json.dumps({"bench": args.bench, "utterances": n, "minutes": round(total_s / 60, 1)}),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
