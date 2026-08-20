# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer"]
# ///
"""Quality gate: coarse WER/CER of each engine vs the mlx-whisper baseline,
plus side-by-side text excerpts for eyeballing.

Usage: uv run --script bench/wer.py <tag>   (tag = audio stem, e.g. bench30)

Reads bench/results/raw/<tag>-<engine>-run1.json, writes bench/results/quality-<tag>.md
and prints it.
"""

import json
import re
import sys
from pathlib import Path

import jiwer

BENCH = Path(__file__).parent
RAW = BENCH / "results" / "raw"
BASELINE = "mlx-whisper"


def normalize(text: str) -> str:
    text = text.lower().replace("ё", "е")
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return " ".join(text.split())


def excerpt(text: str, frac: float, words: int = 40) -> str:
    ws = text.split()
    start = max(0, int(len(ws) * frac) - words // 2)
    return " ".join(ws[start : start + words])


def main() -> None:
    tag = sys.argv[1] if len(sys.argv) > 1 else "bench30"
    texts: dict[str, str] = {}
    for f in sorted(RAW.glob(f"{tag}-*-run1.json")):
        rec = json.loads(f.read_text())
        if "error" in rec or not rec.get("text"):
            continue
        texts[rec["engine"]] = rec["text"]

    if BASELINE not in texts:
        sys.exit(f"baseline '{BASELINE}' transcript not found in {RAW}")

    ref = normalize(texts[BASELINE])
    lines = [
        f"# Quality gate — {tag}",
        "",
        f"Reference: `{BASELINE}` (coarse, not ground truth)",
        "",
    ]
    lines += ["| engine | WER vs baseline | CER | words |", "|---|---|---|---|"]
    for eng, txt in texts.items():
        hyp = normalize(txt)
        wer = jiwer.wer(ref, hyp)
        cer = jiwer.cer(ref, hyp)
        lines.append(f"| {eng} | {wer:.1%} | {cer:.1%} | {len(hyp.split())} |")

    for frac, label in [(0.1, "~10%"), (0.5, "~50%"), (0.9, "~90%")]:
        lines += ["", f"## Excerpt at {label} of transcript", ""]
        for eng, txt in texts.items():
            lines.append(f"**{eng}**: {excerpt(normalize(txt), frac)}")
            lines.append("")

    report = "\n".join(lines)
    out = BENCH / "results" / f"quality-{tag}.md"
    out.write_text(report)
    print(report)


if __name__ == "__main__":
    main()
