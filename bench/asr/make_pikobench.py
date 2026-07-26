"""Assemble piko-audio-bench: a single compact eval set sampled from the
per-source cells materialized by eval_prep.py.

Usage: python bench/make_pikobench.py [--minutes-per-source 5]

Deterministic sampling: utterances are taken evenly spaced across each source
cell (no RNG), so the bench is reproducible from the same cells. Output:
bench/audio/pikobench/{*.wav, refs.jsonl} with source+lang on every ref.
"""

import argparse
import json
import shutil
from pathlib import Path

BENCH = Path(__file__).parent
SOURCES = {
    # source dir -> language. FLEURS-only by decision: one canonical domain for
    # every language keeps cross-language numbers comparable (and comparable to
    # published results). Spontaneous/far-field stress sources were dropped.
    "fleurs_ru": "ru",
    "fleurs_en": "en",
    "fleurs_de": "de",
    "fleurs_fr": "fr",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minutes-per-source", type=float, default=5.0)
    args = parser.parse_args()

    out_dir = BENCH / "audio" / "pikobench"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    all_refs = []
    for source, lang in SOURCES.items():
        src_dir = BENCH / "audio" / "eval" / source
        refs_file = src_dir / "refs.jsonl"
        if not refs_file.exists():
            print(f"skip {source}: not materialized")
            continue
        refs = [json.loads(ln) for ln in refs_file.open()]
        total_s = sum(r["duration_s"] for r in refs)
        budget_s = args.minutes_per_source * 60
        # evenly spaced pick: step chosen so the selected subset ≈ budget
        step = max(1, round(total_s / budget_s))
        picked, acc = [], 0.0
        for i in range(0, len(refs), step):
            if acc >= budget_s:
                break
            picked.append(refs[i])
            acc += refs[i]["duration_s"]
        for r in picked:
            shutil.copy2(src_dir / f"{r['id']}.wav", out_dir / f"{r['id']}.wav")
            all_refs.append({**r, "source": source, "lang": lang})
        print(f"{source}: {len(picked)} utts, {acc / 60:.1f} min")

    with (out_dir / "refs.jsonl").open("w") as f:
        for r in all_refs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    total = sum(r["duration_s"] for r in all_refs)
    print(f"pikobench: {len(all_refs)} utts, {total / 60:.1f} min total")


if __name__ == "__main__":
    main()
