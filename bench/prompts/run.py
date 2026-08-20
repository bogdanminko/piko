"""Run one prompt target's candidates across the shipped tiers.

    uv run python bench/prompts/run.py --target extract --tag r1
    uv run python bench/prompts/run.py --target due --tiers balanced --tag probe

One subprocess per tier, one model load inside it, every (variant, case) pair
run against that load. A fresh process per tier rather than three loads in one
is what keeps peak memory readable and stops one tier's allocator state from
following the next one around.

Greedy decoding with a fixed seed, so a cell is one run and not an average: the
noise this harness has to fear is the judge's, not the sampler's. Wall-clock is
recorded but never ranked on — bench/asr learned that a blocked A/B on this
machine drifts ~19% over twenty minutes, which is larger than any prompt-level
effect. Generation *tokens* are the cost signal, and they are exact.

Writes results/<tag>/raw.jsonl as it goes, then builds the blind judging packets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import metrics as metrics_mod  # noqa: E402
import tasks  # noqa: E402

CASES = HERE / "cases"
VARIANTS = HERE / "variants"
RESULTS = HERE / "results"

TIERS = ("fast", "balanced", "quality")


# --- inputs ----------------------------------------------------------------


def load_cases(target: str, only: list[str] | None) -> list[dict]:
    folder = CASES / target
    picked = []
    for path in sorted(folder.glob("*.json")):
        case = json.loads(path.read_text())
        case.setdefault("id", path.stem)
        if only and case["id"] not in only:
            continue
        picked.append(case)
    if not picked:
        raise SystemExit(f"no cases in {folder}" + (f" matching {only}" if only else ""))
    return picked


def load_variants(target: str, only: list[str] | None) -> list[dict]:
    folder = VARIANTS / target
    picked = []
    for path in sorted(folder.glob("*.txt")):
        if only and path.stem not in only:
            continue
        text = path.read_text().rstrip("\n")
        picked.append({"id": path.stem, "text": text, "path": str(path.relative_to(HERE.parent))})
    if not picked:
        raise SystemExit(f"no variants in {folder}" + (f" matching {only}" if only else ""))
    return picked


def sample_id(tag: str, target: str, case: str, variant: str, tier: str) -> str:
    seed = f"{tag}|{target}|{case}|{variant}|{tier}"
    return hashlib.sha1(seed.encode()).hexdigest()[:8]  # noqa: S324 — a label, not a secret


# --- the worker (one tier, one model load) ---------------------------------


def run_tier(target: str, tier: str, tag: str, cases: list[dict], variants: list[dict]) -> None:
    from piko.core.llm import SamplingParams, open_session

    out_path = RESULTS / tag / "raw.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # The product's own defaults. A prompt tuned under sampling settings nobody
    # ships is a prompt tuned for a different product.
    sampling = SamplingParams(temperature=0.0, seed=0)

    say(f"[{tier}] loading …")
    started = time.perf_counter()
    session = open_session({"provider": "mlx", "tier": tier})
    session.warmup()  # first decode compiles Metal kernels; keep it out of the numbers
    say(f"[{tier}] ready in {time.perf_counter() - started:.1f}s")

    try:
        with out_path.open("a") as out:
            for variant in variants:
                for case in cases:
                    built = tasks.build(target, variant["text"], case)
                    t0 = time.perf_counter()
                    result = session.generate(
                        built.messages, sampling=sampling, json_schema=built.schema
                    )
                    wall = time.perf_counter() - t0
                    measured = metrics_mod.measure(target, case, result.text, built.valid_refs)
                    row = {
                        "sample_id": sample_id(tag, target, case["id"], variant["id"], tier),
                        "tag": tag,
                        "target": target,
                        "case": case["id"],
                        "variant": variant["id"],
                        "tier": tier,
                        "prompt_tokens": result.prompt_tokens,
                        "generation_tokens": result.generation_tokens,
                        "finish_reason": result.finish_reason,
                        "wall_s": round(wall, 2),
                        "peak_memory_mb": (
                            round(result.peak_memory_mb) if result.peak_memory_mb else None
                        ),
                        "system_chars": len(built.messages[0]["content"]),
                        "raw": result.text,
                        "metrics": measured,
                    }
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    say(
                        f"[{tier}] {variant['id']:<24} {case['id']:<22} "
                        f"{result.generation_tokens:>5} tok {wall:>6.1f}s  "
                        f"{_verdict(target, measured)}"
                    )
    finally:
        session.close()


def _verdict(target: str, m: dict) -> str:
    """One line a human can read while it runs, not a score."""
    if not m.get("json_ok"):
        return "PARSE FAIL"
    if target == "due":
        return f"dates {m['due_right']}/{m['due_total']} invented={m['due_invented']}"
    flags = []
    if m.get("refs_bad"):
        flags.append(f"bad_refs={m['refs_bad']}")
    if m.get("refs_missing"):
        flags.append(f"no_ref={m['refs_missing']}")
    if not m.get("lang_ok", True):
        flags.append(f"lang={m.get('lang_detected')}")
    if m.get("trap_hits"):
        flags.append(f"traps={len(m['trap_hits'])}")
    if m.get("padded_empty"):
        flags.append("padded=" + ",".join(m["padded_empty"]))
    if m.get("owner_leaks"):
        flags.append("owner_leak")
    if m.get("over_budget"):
        flags.append("over=" + ",".join(m["over_budget"]))
    return " ".join(flags) or "clean"


def say(message: str) -> None:
    print(message, flush=True)  # noqa: T201 — a research script, stdout is for humans


# --- blind judging packets -------------------------------------------------


def build_packets(target: str, tag: str, cases: list[dict]) -> None:
    """One markdown per case: the evidence, the key, and every output shuffled.

    Comparative rather than absolute — the same reader scoring eight outputs of
    one meeting side by side is far more consistent than scoring them a day
    apart in isolation, and consistency is what a leaderboard is made of.

    Which sample came from which variant lives in key.json and nowhere else. The
    judge reads the packets, writes scores.json, and only then opens the key.
    That is not ceremony: knowing which output is "the candidate I just wrote"
    is exactly the bias this whole exercise cannot afford.
    """
    run_dir = RESULTS / tag
    rows = [
        json.loads(line)
        for line in (run_dir / "raw.jsonl").read_text().splitlines()
        if line.strip()
    ]
    rows = [row for row in rows if row["target"] == target]
    if not rows:
        return

    packets = run_dir / "judge" / target
    packets.mkdir(parents=True, exist_ok=True)
    by_case: dict[str, list[dict]] = {}
    for row in rows:
        by_case.setdefault(row["case"], []).append(row)

    # Merged, not replaced: a round covers several targets and each one rebuilds
    # its own packets, so writing this file fresh each time left it describing
    # whichever target ran last — and a key that silently forgets two thirds of
    # a round is worse than no key, because it looks complete.
    key_path = run_dir / "key.json"
    key = json.loads(key_path.read_text()) if key_path.exists() else {}
    key.update(
        {
            row["sample_id"]: {
                "target": row["target"],
                "case": row["case"],
                "variant": row["variant"],
                "tier": row["tier"],
            }
            for row in rows
        }
    )
    key_path.write_text(json.dumps(key, indent=2, ensure_ascii=False))

    cases_by_id = {case["id"]: case for case in cases}
    pending: list[str] = []
    for case_id, group in sorted(by_case.items()):
        # Seeded on the tag so a re-run of the same round produces the same
        # packet, and a new round reshuffles.
        random.Random(f"{tag}|{case_id}").shuffle(group)
        (packets / f"{case_id}.md").write_text(_packet(cases_by_id[case_id], group))
        pending.extend(row["sample_id"] for row in group)

    template = {
        sid: {"faithfulness": None, "coverage": None, "bullshit_free": None, "actionability": None,
              "note": ""}
        for sid in pending
    }
    scores_path = run_dir / "judge" / f"scores.{target}.json"
    if not scores_path.exists():
        scores_path.write_text(json.dumps(template, indent=2, ensure_ascii=False))
    say(f"\njudging packets → {packets}\nscore into        → {scores_path}")


def _packet(case: dict, group: list[dict]) -> str:
    parts = [
        f"# {case['id']} — {len(group)} outputs to score",
        "",
        "Score every sample below on the four axes in "
        "`.claude/skills/prompt-lab/references/rubric.md`. Do not open `key.json` "
        "until the scores are written.",
        "",
        "## Evidence",
        "",
    ]
    if case["task"] == "due":
        parts += [f"Meeting held {case['meeting_date']} ({case['meeting_weekday']}).", ""]
        parts += [f"- `[{i}]` {phrase}" for i, phrase in enumerate(case["deadlines"])]
    else:
        built = tasks.build(case["task"], "{language}{notes_rules}", case)
        parts += ["```", *[line.render() for line in built.lines], "```"]
        if case.get("notes"):
            parts += ["", "**Typed notes** (authoritative over the transcript):", ""]
            # An untimed note is real — an import has no clock, and a line added
            # before Summarize is worth the same. It just cannot be a citation.
            parts += [
                f"- `{note['at']}s` {note['text']}"
                if note.get("at") is not None
                else f"- _(no time)_ {note['text']}"
                for note in case["notes"]
            ]
        if case["task"] == "reduce":
            parts += [
                "",
                "**Partials handed to the reduce step** (this is its actual input):",
                "",
                "```json",
                json.dumps(case["partials"], ensure_ascii=False, indent=2),
                "```",
            ]

    parts += ["", "## Answer key", "", "```json",
              json.dumps(case.get("key", {}), ensure_ascii=False, indent=2), "```", "",
              "## Samples", ""]
    for row in group:
        parts += [
            f"### {row['sample_id']}",
            "",
            f"`{row['generation_tokens']} generated tokens`",
            "",
            "```json",
            row["raw"].strip(),
            "```",
            "",
        ]
    return "\n".join(parts) + "\n"


# --- driver ----------------------------------------------------------------


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, choices=sorted(tasks.TARGETS))
    ap.add_argument("--tag", required=True, help="round name; results/<tag>/")
    ap.add_argument("--tiers", default=",".join(TIERS))
    ap.add_argument("--variants", default="", help="comma-separated stems; default all")
    ap.add_argument("--cases", default="", help="comma-separated ids; default all")
    ap.add_argument("--packets-only", action="store_true", help="rebuild judging packets only")
    ap.add_argument("--_tier", help=argparse.SUPPRESS)
    args = ap.parse_args()

    only_cases = [c for c in args.cases.split(",") if c] or None
    only_variants = [v for v in args.variants.split(",") if v] or None
    cases = load_cases(args.target, only_cases)
    variants = load_variants(args.target, only_variants)

    if args._tier:
        run_tier(args.target, args._tier, args.tag, cases, variants)
        return

    if args.packets_only:
        build_packets(args.target, args.tag, cases)
        return

    tiers = [t for t in args.tiers.split(",") if t]
    say(
        f"{args.target}: {len(variants)} variants x {len(cases)} cases x {len(tiers)} tiers "
        f"= {len(variants) * len(cases) * len(tiers)} runs\n"
    )
    for tier in tiers:
        # A fresh interpreter per tier: nothing carries over, and a tier that
        # cannot fit on this machine fails alone instead of taking the run.
        proc = subprocess.run(
            [sys.executable, __file__, "--target", args.target, "--tag", args.tag,
             "--_tier", tier, "--variants", args.variants, "--cases", args.cases],
            cwd=str(HERE.parent.parent),
        )
        if proc.returncode != 0:
            say(f"[{tier}] FAILED (exit {proc.returncode}) — continuing with the rest")

    build_packets(args.target, args.tag, cases)


if __name__ == "__main__":
    main()
