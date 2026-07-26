# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "torch==2.10.*",
#   "torchaudio==2.10.*",
#   "transformers==5.*",
#   "hydra-core",
#   "omegaconf",
#   "soundfile",
#   "sentencepiece",
#   "huggingface-hub",
#   "numpy",
# ]
# ///
"""Batch eval runner for GigaAM (ai-sage/GigaAM-Multilingual, torch + trust_remote_code).

Deliberately an inline-dependency script: the torch/transformers stack stays in
its own uv environment and never touches the app's .venv (Piko ships MLX only).

The repo publishes its variants as git revisions, so the model argument carries
one: "ai-sage/GigaAM-Multilingual@ctc" (220M) or "...@large_ctc" (600M).

Usage: uv run --script eval_gigaam.py <eval_dir> <repo[@revision]> <out_jsonl> [--device mps|cpu] [--limit N]
"""

import json
import re
import sys
import tempfile
import time
from pathlib import Path

VENDOR = Path(__file__).resolve().parent.parent / "vendor"

# transformers' `check_imports` statically scans the remote-code file for import
# statements and refuses to load unless every one of them resolves. GigaAM's
# modeling file imports pyannote for `transcribe_longform`'s VAD segmentation —
# a whole second torch stack plus a gated HF model, for a code path this bench
# never takes (pikobench utterances are all well under the 30s short-form limit).
# So mirror the repo locally and turn those imports into honest runtime errors.
PYANNOTE_IMPORT = re.compile(r"^(\s*)from pyannote\S* import .*$", re.MULTILINE)
PYANNOTE_STUB = r'\1raise ImportError("pyannote stripped for bench: longform unavailable")'


def local_model_dir(repo: str, revision: str) -> Path:
    from huggingface_hub import snapshot_download

    dest = VENDOR / f"gigaam-{revision or 'main'}"
    snapshot_download(repo_id=repo, revision=revision or None, local_dir=str(dest))

    modeling = dest / "modeling_gigaam.py"
    src = modeling.read_text()
    patched, n = PYANNOTE_IMPORT.subn(PYANNOTE_STUB, src)
    if n:
        modeling.write_text(patched)
        print(f"patched out {n} pyannote imports in {modeling}", file=sys.stderr)
    return dest


# modeling_gigaam.py: LONGFORM_THRESHOLD = 25 * SAMPLE_RATE — transcribe() hard-
# rejects anything longer, so stay a margin under it.
SHORTFORM_LIMIT_S = 24.0


def transcribe_file(model, wav: str, tmpdir: str, max_s: float = 20.0) -> str:
    """Transcribe one file, chunking if it exceeds GigaAM's short-form limit.

    Crude fixed-window splitting with no overlap: a word straddling a boundary
    gets clipped. That is fine here — pikobench has a handful of long utterances
    — but real longform needs VAD segmentation, which is the pyannote path
    stripped above.
    """
    import soundfile as sf

    info = sf.info(wav)
    if info.duration <= SHORTFORM_LIMIT_S:
        return model.transcribe(wav).text

    data, sr = sf.read(wav)
    step = int(max_s * sr)
    parts = []
    for i, start in enumerate(range(0, len(data), step)):
        chunk = Path(tmpdir) / f"{Path(wav).stem}_{i}.wav"
        sf.write(str(chunk), data[start : start + step], sr)
        parts.append(model.transcribe(str(chunk)).text)
    print(f"  (chunked {info.duration:.0f}s into {len(parts)} windows)", file=sys.stderr)
    return " ".join(p for p in parts if p)


def main() -> None:
    eval_dir = Path(sys.argv[1])
    model_arg = sys.argv[2]
    out = sys.argv[3]
    argv = sys.argv[4:]
    device = argv[argv.index("--device") + 1] if "--device" in argv else "mps"
    limit = int(argv[argv.index("--limit") + 1]) if "--limit" in argv else None

    repo, _, revision = model_arg.partition("@")

    import torch
    from transformers import AutoModel

    if device == "mps" and not torch.backends.mps.is_available():
        print("mps unavailable, falling back to cpu", file=sys.stderr)
        device = "cpu"

    model_dir = local_model_dir(repo, revision)

    t0 = time.perf_counter()
    model = AutoModel.from_pretrained(str(model_dir), trust_remote_code=True)
    model = model.to(device).eval()
    load_s = time.perf_counter() - t0
    print(f"loaded {model_arg} on {device} in {load_s:.1f}s", file=sys.stderr)

    refs = [json.loads(ln) for ln in (eval_dir / "refs.jsonl").open()]
    if limit:
        refs = refs[:limit]

    with tempfile.TemporaryDirectory() as tmpdir, open(out, "w") as f:
        f.write(
            json.dumps({"meta": True, "model": model_arg, "device": device, "load_s": load_s})
            + "\n"
        )
        for i, r in enumerate(refs, 1):
            wav = str(eval_dir / f"{r['id']}.wav")
            t1 = time.perf_counter()
            hyp = transcribe_file(model, wav, tmpdir)
            dt = time.perf_counter() - t1
            f.write(
                json.dumps(
                    {"id": r["id"], "hyp": hyp, "transcribe_s": round(dt, 4)},
                    ensure_ascii=False,
                )
                + "\n"
            )
            f.flush()
            print(f"  [{i}/{len(refs)}] {r['id']} {dt:.2f}s", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
