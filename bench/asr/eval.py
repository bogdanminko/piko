# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer"]
# ///
"""Eval v2 orchestrator + scorer.

Usage:
  uv run --script bench/eval.py run <bench> <model_key>   # run one (bench, model) cell
  uv run --script bench/eval.py score                     # score all hyps found, print report

Cells write hyps to bench/results/eval/<bench>--<model_key>.jsonl.
`score` computes WER / CER / insertion rate / speed (s per min of audio, RTF)
per cell and writes bench/results/EVAL.md.

Models (what Piko ships or plans to):
  tiny      mlx-whisper  mlx-community/whisper-tiny
  turbo     mlx-whisper  mlx-community/whisper-large-v3-turbo
  large8bit mlx-whisper  mlx-community/whisper-large-v3-mlx-8bit
  parakeet  parakeet-mlx mlx-community/parakeet-tdt-0.6b-v3
"""

import json
import re
import subprocess
import sys
from pathlib import Path

BENCH = Path(__file__).parent
EVAL_AUDIO = BENCH / "audio" / "eval"
EVAL_OUT = BENCH / "results" / "eval"

LANGS = {"fleurs_ru": "ru", "fleurs_en": "en", "golos_farfield": "ru", "ami": "en"}

MODELS = {
    "tiny": ("mlx-whisper", "mlx-community/whisper-tiny"),
    "turbo": ("mlx-whisper", "mlx-community/whisper-large-v3-turbo"),
    "large8bit": ("mlx-whisper", "mlx-community/whisper-large-v3-mlx-8bit"),
    "parakeet": ("parakeet-mlx", "mlx-community/parakeet-tdt-0.6b-v3"),
    "nemotron": ("mlx-audio", "mlx-community/nemotron-3.5-asr-streaming-0.6b"),
    "qwen3asr": ("mlx-audio", "mlx-community/Qwen3-ASR-0.6B-8bit"),
    # engine variants on identical weights — the engine comparison lives in the
    # same leaderboard as the model comparison
    "turbo@whisper.cpp": ("whisper-cpp", "GGML_MODEL"),
    "turbo@transcribe-rs": ("transcribe-rs", "GGML_MODEL"),
    "turbo@mlx-audio": ("mlx-audio", "openai/whisper-large-v3-turbo"),
    "parakeet@transcribe-rs": ("transcribe-rs-parakeet", "PARAKEET_ONNX_DIR"),
    "parakeet@transcribe-rs-fp16": ("transcribe-rs-parakeet", "PARAKEET_ONNX_FP16_DIR"),
    "parakeet@mlx-audio": ("mlx-audio-bf16", "mlx-community/parakeet-tdt-0.6b-v3"),
}

GGML_MODEL = str(BENCH / "vendor" / "ggml-large-v3-turbo.bin")
PARAKEET_ONNX_DIR = str(BENCH / "vendor" / "parakeet-onnx")
PARAKEET_ONNX_FP16_DIR = str(BENCH / "vendor" / "parakeet-onnx-fp16")


def normalize(text: str) -> str:
    text = text.lower().replace("ё", "е")
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return " ".join(text.split())


def bench_dir(bench: str) -> Path:
    d = EVAL_AUDIO / bench
    return d if d.exists() else BENCH / "audio" / bench


def run_cell(bench: str, model_key: str) -> None:
    engine, repo = MODELS[model_key]
    eval_dir = bench_dir(bench)
    if not (eval_dir / "refs.jsonl").exists():
        sys.exit(f"{bench}: refs.jsonl not found — run eval_prep.py first")
    EVAL_OUT.mkdir(parents=True, exist_ok=True)
    out = EVAL_OUT / f"{bench}--{model_key}.jsonl"

    if engine == "mlx-whisper":
        cmd = [
            "uv",
            "run",
            "python",
            str(BENCH / "engines" / "eval_mlx_whisper.py"),
            str(eval_dir),
            repo,
            str(out),
        ]
        if LANGS.get(bench):
            cmd += ["--lang", LANGS[bench]]
    elif engine == "parakeet-mlx":
        cmd = [
            "uv",
            "run",
            "--script",
            str(BENCH / "engines" / "eval_parakeet.py"),
            str(eval_dir),
            repo,
            str(out),
        ]
    elif engine in ("whisper-cpp", "transcribe-rs"):
        cmd = [
            "uv",
            "run",
            "python",
            str(BENCH / "engines" / "eval_native.py"),
            engine,
            str(eval_dir),
            GGML_MODEL,
            str(out),
        ]
    elif engine == "transcribe-rs-parakeet":
        model_dir = (
            PARAKEET_ONNX_FP16_DIR if repo == "PARAKEET_ONNX_FP16_DIR" else PARAKEET_ONNX_DIR
        )
        cmd = [
            "uv",
            "run",
            "python",
            str(BENCH / "engines" / "eval_native.py"),
            engine,
            str(eval_dir),
            model_dir,
            str(out),
        ]
    elif engine == "mlx-audio-bf16":
        cmd = [
            "uv",
            "run",
            "--script",
            str(BENCH / "engines" / "eval_mlx_audio.py"),
            str(eval_dir),
            repo,
            str(out),
            "bf16",
        ]
    else:
        cmd = [
            "uv",
            "run",
            "--script",
            str(BENCH / "engines" / "eval_mlx_audio.py"),
            str(eval_dir),
            repo,
            str(out),
        ]
    print(f"[{bench} × {model_key}] running ...", file=sys.stderr, flush=True)
    subprocess.run(cmd, cwd=BENCH.parent, check=True)


def score() -> None:
    import jiwer

    rows = []
    for hyp_file in sorted(EVAL_OUT.glob("*--*.jsonl")):
        bench, model_key = hyp_file.stem.split("--")
        refs = {
            j["id"]: j for ln in (bench_dir(bench) / "refs.jsonl").open() if (j := json.loads(ln))
        }
        hyps, load_s = {}, None
        for ln in hyp_file.open():
            j = json.loads(ln)
            if j.get("meta"):
                load_s = j["load_s"]
                continue
            hyps[j["id"]] = j

        ids = [i for i in refs if i in hyps]
        if not ids:
            continue

        # slice by source when refs carry one (pikobench), else one slice = bench
        slices: dict[str, list[str]] = {}
        for i in ids:
            key = refs[i].get("source", bench)
            slices.setdefault(key, []).append(i)
        slices["ALL"] = ids

        for slice_name, sids in slices.items():
            pairs = [(normalize(refs[i]["text"]), normalize(hyps[i]["hyp"])) for i in sids]
            pairs = [(r, h) for r, h in pairs if r]
            if not pairs:
                continue
            ref_texts = [r for r, _ in pairs]
            hyp_texts = [h for _, h in pairs]
            measures = jiwer.process_words(ref_texts, hyp_texts)
            cer = jiwer.cer(ref_texts, hyp_texts)
            n_ref_words = sum(len(r.split()) for r in ref_texts)
            audio_s = sum(refs[i]["duration_s"] for i in sids)
            compute_s = sum(hyps[i]["transcribe_s"] for i in sids)
            rows.append(
                {
                    "bench": bench,
                    "slice": slice_name,
                    "model": model_key,
                    "wer": measures.wer,
                    "cer": cer,
                    "ins_rate": measures.insertions / max(n_ref_words, 1),
                    "audio_min": audio_s / 60,
                    "s_per_min": compute_s / (audio_s / 60),
                    "rtf": audio_s / compute_s,
                    "load_s": load_s,
                    "n": len(sids),
                }
            )

    lines = [
        "# Piko ASR eval — quality + on-device speed",
        "",
        "Hardware: Apple M4 Max 36 GB. Speed = pure transcription compute,",
        "model loaded once (load time listed separately).",
        "",
        "| slice | model | WER | CER | ins.rate | sec / min audio | RTF | load s | utts |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in sorted(rows, key=lambda r: (r["slice"] != "ALL", r["slice"], r["wer"])):
        lines.append(
            f"| {r['slice']} | {r['model']} | {r['wer']:.1%} | {r['cer']:.1%} "
            f"| {r['ins_rate']:.1%} | {r['s_per_min']:.2f} | {r['rtf']:.0f}x "
            f"| {r['load_s']:.2f} | {r['n']} |"
        )
    report = "\n".join(lines)
    (BENCH / "results" / "EVAL.md").write_text(report + "\n")
    print(report)


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "score":
        score()
    elif len(sys.argv) == 4 and sys.argv[1] == "run":
        run_cell(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
