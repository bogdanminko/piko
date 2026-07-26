"""Batch eval runner for native whisper engines (whisper.cpp CLI and
transcribe-rs) on an eval dir. Groups files by language (one model load +
one process per group), writes standard hyps JSONL.

Per-file timing:
- transcribe-rs reports it directly;
- whisper-cli doesn't, so group compute time (wall minus load) is apportioned
  to files proportionally to their audio duration.

Usage: python eval_native.py <whisper-cpp|transcribe-rs|transcribe-rs-parakeet> <eval_dir> <model> <out_jsonl>

For transcribe-rs-parakeet, <model> is the ONNX model directory (expects
encoder-model.onnx[.data], decoder_joint-model.onnx, nemo128.onnx, vocab.txt —
the istupakov/parakeet-tdt-0.6b-v3-onnx layout). All files run as one group —
Parakeet has no language parameter, it infers language from audio.
"""

import argparse
import json
import re
import subprocess
import time
from collections import defaultdict
from pathlib import Path

ASR = Path(__file__).parent.parent
WHISPER_CLI = ASR / "vendor" / "whisper.cpp" / "build" / "bin" / "whisper-cli"
TRS_BIN = (
    Path(__file__).parent / "transcribe_rs_bench" / "target" / "release" / "transcribe_rs_bench"
)


def run_whisper_cpp(files: list[dict], lang: str, model: str) -> tuple[float, float, dict]:
    """Returns (load_s, compute_s, {id: text}). Parses `-oj` JSON outputs."""
    paths = [f["path"] for f in files]
    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(WHISPER_CLI), "-m", model, "-l", lang, "-oj", *paths],
        capture_output=True,
        text=True,
        check=True,
    )
    wall = time.perf_counter() - t0
    m = re.search(r"load time\s*=\s*([\d.]+)\s*ms", proc.stderr)
    load_s = float(m.group(1)) / 1000 if m else 0.0

    hyps = {}
    for f in files:
        jf = Path(f["path"] + ".json")  # whisper-cli appends .json to the input name
        data = json.loads(jf.read_text())
        text = " ".join(seg["text"].strip() for seg in data.get("transcription", []))
        hyps[f["id"]] = text
        jf.unlink()
    return load_s, wall - load_s, hyps


def run_transcribe_rs_parakeet(
    files: list[dict], model_dir: str
) -> tuple[float, float, dict, dict]:
    """Returns (load_s, compute_s, {id: text}, {id: transcribe_s})."""
    paths = [f["path"] for f in files]
    proc = subprocess.run(
        [str(TRS_BIN), "--parakeet-batch", model_dir, *paths],
        capture_output=True,
        text=True,
        check=True,
    )
    load_s = 0.0
    by_path = {}
    for ln in proc.stdout.splitlines():
        j = json.loads(ln)
        if j.get("meta"):
            load_s = j["load_s"]
        else:
            by_path[j["file"]] = j
    hyps = {f["id"]: by_path[f["path"]]["text"] for f in files}
    times = {f["id"]: by_path[f["path"]]["transcribe_s"] for f in files}
    return load_s, sum(times.values()), hyps, times


def run_transcribe_rs(files: list[dict], lang: str, model: str) -> tuple[float, float, dict, dict]:
    """Returns (load_s, compute_s, {id: text}, {id: transcribe_s})."""
    paths = [f["path"] for f in files]
    proc = subprocess.run(
        [str(TRS_BIN), "--batch", model, lang, *paths],
        capture_output=True,
        text=True,
        check=True,
    )
    load_s = 0.0
    by_path = {}
    for ln in proc.stdout.splitlines():
        j = json.loads(ln)
        if j.get("meta"):
            load_s = j["load_s"]
        else:
            by_path[j["file"]] = j
    hyps = {f["id"]: by_path[f["path"]]["text"] for f in files}
    times = {f["id"]: by_path[f["path"]]["transcribe_s"] for f in files}
    return load_s, sum(times.values()), hyps, times


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "engine", choices=["whisper-cpp", "transcribe-rs", "transcribe-rs-parakeet"]
    )
    parser.add_argument("eval_dir")
    parser.add_argument("model")
    parser.add_argument("out")
    args = parser.parse_args()

    eval_dir = Path(args.eval_dir)
    refs = [json.loads(ln) for ln in (eval_dir / "refs.jsonl").open()]

    all_hyps: dict[str, str] = {}
    all_times: dict[str, float] = {}
    max_load = 0.0

    if args.engine == "transcribe-rs-parakeet":
        files = [
            {"id": r["id"], "path": str(eval_dir / f"{r['id']}.wav"), "duration_s": r["duration_s"]}
            for r in refs
        ]
        load_s, _, hyps, times = run_transcribe_rs_parakeet(files, args.model)
        all_hyps.update(hyps)
        all_times.update(times)
        max_load = load_s
    else:
        groups: dict[str, list[dict]] = defaultdict(list)
        for r in refs:
            groups[r.get("lang", "auto")].append(
                {
                    "id": r["id"],
                    "path": str(eval_dir / f"{r['id']}.wav"),
                    "duration_s": r["duration_s"],
                }
            )
        for lang, files in groups.items():
            if args.engine == "whisper-cpp":
                load_s, compute_s, hyps = run_whisper_cpp(files, lang, args.model)
                group_dur = sum(f["duration_s"] for f in files)
                times = {f["id"]: compute_s * f["duration_s"] / group_dur for f in files}
            else:
                load_s, compute_s, hyps, times = run_transcribe_rs(files, lang, args.model)
            all_hyps.update(hyps)
            all_times.update(times)
            max_load = max(max_load, load_s)

    with open(args.out, "w") as f:
        f.write(json.dumps({"meta": True, "model": args.model, "load_s": max_load}) + "\n")
        for r in refs:
            if r["id"] not in all_hyps:
                continue
            f.write(
                json.dumps(
                    {
                        "id": r["id"],
                        "hyp": all_hyps[r["id"]],
                        "transcribe_s": round(all_times[r["id"]], 4),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )


if __name__ == "__main__":
    main()
