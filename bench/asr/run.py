"""ASR benchmark orchestrator.

Runs every engine on the given WAV, N repetitions each, in fresh processes,
wrapped in /usr/bin/time -l to capture peak RSS. Collects per-run JSON into
bench/results/raw/ and prints a summary table.

Usage:
    uv run python bench/run.py bench/audio/probe.wav --runs 1     # smoke
    uv run python bench/run.py bench/audio/bench30.wav --runs 3   # full

Engines self-report load_s / transcribe_s on stdout as one JSON line
(whisper-cli is special-cased: timings parsed from its stderr).
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
import wave
from pathlib import Path

BENCH = Path(__file__).parent
VENDOR = BENCH / "vendor"
ENGINES_DIR = BENCH / "engines"
RESULTS = BENCH / "results"

WHISPER_CLI = VENDOR / "whisper.cpp" / "build" / "bin" / "whisper-cli"
GGML_MODEL = VENDOR / "ggml-large-v3-turbo.bin"
TRS_BIN = ENGINES_DIR / "transcribe_rs_bench" / "target" / "release" / "transcribe_rs_bench"
MLX_WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
PARAKEET_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
LANG = "ru"


def audio_duration_s(path: str) -> float:
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def engine_commands(audio: str) -> dict[str, list[str]]:
    return {
        "mlx-whisper": [
            "uv",
            "run",
            "python",
            str(ENGINES_DIR / "bench_mlx_whisper.py"),
            audio,
            MLX_WHISPER_MODEL,
            "--lang",
            LANG,
        ],
        "mlx-whisper+wordts": [
            "uv",
            "run",
            "python",
            str(ENGINES_DIR / "bench_mlx_whisper.py"),
            audio,
            MLX_WHISPER_MODEL,
            "--lang",
            LANG,
            "--word-timestamps",
        ],
        "whisper.cpp": [
            str(WHISPER_CLI),
            "-m",
            str(GGML_MODEL),
            "-f",
            audio,
            "-l",
            LANG,
        ],
        "transcribe-rs": [str(TRS_BIN), str(GGML_MODEL), audio, LANG],
        "parakeet-mlx": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_parakeet_mlx.py"),
            audio,
            PARAKEET_MODEL,
        ],
        "mlx-audio": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_mlx_audio.py"),
            audio,
            PARAKEET_MODEL,
        ],
        "mlx-audio-bf16": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_mlx_audio.py"),
            audio,
            PARAKEET_MODEL,
            "bf16",
        ],
        "mlx-audio-fp16": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_mlx_audio.py"),
            audio,
            PARAKEET_MODEL,
            "fp16",
        ],
        "mlx-audio-whisper-fp16": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_mlx_audio.py"),
            audio,
            "openai/whisper-large-v3-turbo",
            "fp16",
        ],
        "mlx-audio-whisper-bf16": [
            "uv",
            "run",
            "--script",
            str(ENGINES_DIR / "bench_mlx_audio.py"),
            audio,
            "openai/whisper-large-v3-turbo",
            "bf16",
        ],
    }


def parse_whisper_cli(stdout: str, stderr: str) -> dict:
    """whisper-cli prints the transcript to stdout and timings to stderr."""
    load_ms = total_ms = None
    m = re.search(r"load time\s*=\s*([\d.]+)\s*ms", stderr)
    if m:
        load_ms = float(m.group(1))
    m = re.search(r"total time\s*=\s*([\d.]+)\s*ms", stderr)
    if m:
        total_ms = float(m.group(1))
    text = re.sub(r"\[[\d:., >-]+\]", " ", stdout)  # strip "[00:00:00.000 --> ...]" prefixes
    text = " ".join(text.split())
    out: dict = {"engine": "whisper.cpp", "text": text}
    if load_ms is not None:
        out["load_s"] = load_ms / 1000
    if load_ms is not None and total_ms is not None:
        out["transcribe_s"] = (total_ms - load_ms) / 1000
    return out


def run_once(name: str, cmd: list[str], audio_s: float) -> dict:
    wrapped = ["/usr/bin/time", "-l"] + cmd
    t0 = time.perf_counter()
    proc = subprocess.run(wrapped, capture_output=True, text=True, cwd=BENCH.parent)
    wall_s = time.perf_counter() - t0
    if proc.returncode != 0:
        return {
            "engine": name,
            "error": f"exit {proc.returncode}",
            "stderr_tail": proc.stderr[-2000:],
        }

    rss_mb = None
    m = re.search(r"(\d+)\s+maximum resident set size", proc.stderr)
    if m:
        rss_mb = int(m.group(1)) / (1024 * 1024)

    if name == "whisper.cpp":
        rec = parse_whisper_cli(proc.stdout, proc.stderr)
    else:
        json_line = next((ln for ln in proc.stdout.splitlines() if ln.startswith("{")), None)
        if json_line is None:
            return {
                "engine": name,
                "error": "no JSON on stdout",
                "stdout_tail": proc.stdout[-1000:],
                "stderr_tail": proc.stderr[-1000:],
            }
        rec = json.loads(json_line)

    rec["engine"] = name
    rec["wall_s"] = wall_s
    rec["peak_rss_mb"] = rss_mb
    rec["audio_s"] = audio_s
    if "transcribe_s" in rec:
        rec["rtf"] = audio_s / rec["transcribe_s"]
    return rec


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--only", default=None, help="comma-separated engine names")
    args = parser.parse_args()

    audio = str(Path(args.audio).resolve())
    audio_s = audio_duration_s(audio)
    raw_dir = RESULTS / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    tag = Path(audio).stem

    engines = engine_commands(audio)
    if args.only:
        wanted = args.only.split(",")
        engines = {k: v for k, v in engines.items() if k in wanted}

    summary = []
    for name, cmd in engines.items():
        runs = []
        for i in range(args.runs):
            print(f"[{name}] run {i + 1}/{args.runs} ...", file=sys.stderr, flush=True)
            rec = run_once(name, cmd, audio_s)
            rec["run"] = i + 1
            runs.append(rec)
            out = raw_dir / f"{tag}-{name.replace('/', '_')}-run{i + 1}.json"
            out.write_text(json.dumps(rec, ensure_ascii=False, indent=1))
            if "error" in rec:
                print(f"[{name}] FAILED: {rec['error']}", file=sys.stderr)
                break

        ok = [r for r in runs if "error" not in r]
        if not ok:
            summary.append({"engine": name, "error": runs[-1].get("error")})
            continue
        warm = ok[1:] or ok
        trs = [r["transcribe_s"] for r in warm if "transcribe_s" in r]
        med_tr = statistics.median(trs) if trs else None
        rss = [r["peak_rss_mb"] for r in ok if r.get("peak_rss_mb")]
        summary.append(
            {
                "engine": name,
                "cold_load_s": ok[0].get("load_s"),
                "median_warm_transcribe_s": med_tr,
                "rtf": audio_s / med_tr if med_tr else None,
                "peak_rss_mb": max(rss) if rss else None,
                "cold_wall_s": ok[0]["wall_s"],
                "median_warm_wall_s": statistics.median(r["wall_s"] for r in warm),
            }
        )

    (RESULTS / f"summary-{tag}.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
