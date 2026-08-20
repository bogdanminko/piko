"""Turn a round's runs and judgements into one ranked number per variant.

    uv run python bench/prompts/score.py --tag r1 --target extract [--markdown]

The definition lives in `.claude/skills/prompt-lab/references/rubric.md`; this
file is that definition executed, and the two must not drift.

    PPS = 60 x quality + 15 x reliability + 15 x efficiency + 10 x simplicity

behind three hard gates — parses, cites only real lines, answers in the right
language. A variant that fails one is not ranked at any score, because the
alternative is a weighted sum in which fluent prose buys back an invented
citation. That trade has no acceptable exchange rate for this product, and a
multi-objective score that offers one will eventually take it.

Run it before judging too: everything except `quality` is computable from the
runs alone, and the deterministic half is often enough to kill a candidate.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).parent
RESULTS = HERE / "results"
sys.path.insert(0, str(HERE))

import metrics as metrics_mod  # noqa: E402

# What the judge's four axes are worth to each other. Faithfulness leads because
# an unfaithful summary is worse than no summary — the rest of the axes describe
# how good a true answer is.
AXES = {"faithfulness": 0.35, "coverage": 0.25, "bullshit_free": 0.20, "actionability": 0.20}

WEIGHTS = {"quality": 60.0, "reliability": 15.0, "efficiency": 15.0, "simplicity": 10.0}

# The default tier carries the round. `fast` and `quality` are there to catch a
# prompt that only works on one size of model, not to average it into safety.
TIER_WEIGHTS = {"fast": 0.25, "balanced": 0.50, "quality": 0.25}

# How far below its own headline a variant may fall on the smallest tier before
# it is called out. Below 2B is where a long prompt stops being followed at all.
FRAGILE_DROP = 20.0


# --- per-run reliability ---------------------------------------------------


def reliability(target: str, m: dict) -> float:
    """One run's mechanical soundness, 0..1, from the deterministic metrics.

    Penalties rather than a checklist: these failures co-occur, and a prompt
    that pads one list usually pads two. Losing a fixed amount per occurrence
    keeps a variant that fails twice ranked below one that fails once.
    """
    if not m.get("json_ok"):
        return 0.0
    if target == "due":
        total = m.get("due_total") or 1
        # An invented date is charged on top of simply being wrong: it is the
        # one error that puts a commitment nobody made into somebody's calendar.
        return max(0.0, (m.get("due_right", 0) - 0.5 * m.get("due_invented", 0)) / total)

    score = 1.0
    if not m.get("shape_ok", True):
        score -= 0.20
    score -= 0.15 * len(m.get("padded_empty", []))
    score -= 0.10 * len(m.get("trap_hits", []))
    score -= 0.10 * len(m.get("owner_leaks", []))
    score -= 0.05 * len(m.get("owner_unknown", []))
    score -= 0.05 * (len(m.get("count_over", [])) + len(m.get("count_under", [])))
    score -= 0.10 * len(m.get("over_budget", []))
    # Items with no usable citation are dropped by `_resolve` on the way to the
    # screen, so this is content the reader never sees.
    total_refs = m.get("refs_total") or 0
    if total_refs:
        score -= 0.5 * m.get("refs_missing", 0) / total_refs
    score -= 0.05 * (len(m.get("hedges", [])) + len(m.get("vague", [])))
    if m.get("brief_echo", 0) >= 0.5:
        score -= 0.15
    return max(0.0, min(1.0, score))


# --- rollup ----------------------------------------------------------------


def load(tag: str, target: str) -> tuple[list[dict], dict, dict]:
    run_dir = RESULTS / tag
    rows = [
        json.loads(line)
        for line in (run_dir / "raw.jsonl").read_text().splitlines()
        if line.strip()
    ]
    rows = [row for row in rows if row["target"] == target]
    scores_path = run_dir / "judge" / f"scores.{target}.json"
    judged = json.loads(scores_path.read_text()) if scores_path.exists() else {}
    key_path = run_dir / "key.json"
    key = json.loads(key_path.read_text()) if key_path.exists() else {}
    return rows, judged, key


def quality_of(target: str, rows: list[dict], judged: dict) -> float | None:
    """0..1. Judged for prose targets; exact-match accuracy for `due`.

    One scale on purpose. `due` is arithmetic and spending judgement on it would
    add the judge's noise to a fact, but its accuracy belongs in the same column
    as everything else or the leaderboard cannot be read across targets.
    """
    if target == "due":
        values = [row["metrics"].get("due_accuracy") for row in rows]
        clean = [v for v in values if v is not None]
        return round(statistics.mean(clean), 4) if clean else None

    per_run: list[float] = []
    for row in rows:
        entry = judged.get(row["sample_id"]) or {}
        if any(entry.get(axis) is None for axis in AXES):
            continue
        per_run.append(sum(entry[axis] * weight for axis, weight in AXES.items()) / 5.0)
    return round(statistics.mean(per_run), 4) if len(per_run) == len(rows) else None


def summarize(tag: str, target: str) -> dict[str, Any]:
    rows, judged, _ = load(tag, target)
    if not rows:
        raise SystemExit(f"no rows for target {target!r} in {RESULTS / tag / 'raw.jsonl'}")

    cells: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        cells.setdefault((row["variant"], row["tier"]), []).append(row)

    # Cost and length are compared within a tier: tokens per second and per
    # answer differ enough between 2B and 9B that a cross-tier ratio would rank
    # the model, not the prompt.
    best_tokens: dict[str, float] = {}
    for (variant, tier), group in cells.items():  # noqa: B007 — variant unused here
        median = statistics.median(row["generation_tokens"] for row in group)
        best_tokens[tier] = min(best_tokens.get(tier, median), median)

    fit_lengths = [
        row["system_chars"]
        for (variant, tier), group in cells.items()
        for row in group
        if _gates(target, group)["fit"]
    ]
    shortest = min(fit_lengths) if fit_lengths else min(row["system_chars"] for row in rows)

    out: dict[str, Any] = {"tag": tag, "target": target, "variants": {}}
    for (variant, tier), group in sorted(cells.items()):
        gates = _gates(target, group)
        tokens = statistics.median(row["generation_tokens"] for row in group)
        chars = group[0]["system_chars"]
        quality = quality_of(target, group, judged)
        parts = {
            "quality": quality,
            "reliability": round(
                statistics.mean(reliability(target, row["metrics"]) for row in group), 4
            ),
            "efficiency": round(min(1.0, best_tokens[tier] / tokens), 4) if tokens else 0.0,
            "simplicity": round(min(1.0, shortest / chars), 4),
        }
        pps = (
            round(sum(WEIGHTS[k] * v for k, v in parts.items()), 1)
            if gates["fit"] and quality is not None
            else None
        )
        entry = out["variants"].setdefault(variant, {"system_chars": chars, "tiers": {}})
        entry["tiers"][tier] = {
            **parts,
            "gates": gates,
            "pps": pps,
            "median_gen_tokens": tokens,
            "median_wall_s": round(statistics.median(row["wall_s"] for row in group), 1),
            "peak_memory_mb": max((row["peak_memory_mb"] or 0) for row in group) or None,
            "runs": len(group),
        }

    for variant, entry in out["variants"].items():  # noqa: B007
        scored = {
            tier: cell["pps"] for tier, cell in entry["tiers"].items() if cell["pps"] is not None
        }
        if len(scored) == len(TIER_WEIGHTS):
            headline = sum(TIER_WEIGHTS[tier] * pps for tier, pps in scored.items())
            entry["headline"] = round(headline, 1)
            entry["tier_fragile"] = scored["fast"] < headline - FRAGILE_DROP
        else:
            entry["headline"] = None
            entry["tier_fragile"] = None
        entry["unfit_on"] = [
            tier for tier, cell in entry["tiers"].items() if not cell["gates"]["fit"]
        ]
    return out


def _gates(target: str, group: list[dict]) -> dict[str, Any]:
    if target == "due":
        parse = sum(1 for row in group if row["metrics"].get("json_ok")) / len(group)
        return {"parse_rate": round(parse, 3), "refs_bad": 0, "lang_rate": 1.0,
                "fit": parse >= 0.95}
    return metrics_mod.gates_passed(group)


# --- output ----------------------------------------------------------------


def table(result: dict[str, Any]) -> str:
    lines = [
        f"{'variant':<16} {'tier':<9} {'PPS':>6} {'qual':>5} {'rel':>5} {'eff':>5} "
        f"{'simp':>5} {'tok':>5} {'gates':>26}"
    ]
    order = sorted(
        result["variants"].items(),
        key=lambda kv: (kv[1]["headline"] is None, -(kv[1]["headline"] or 0)),
    )
    for variant, entry in order:
        for tier in ("fast", "balanced", "quality"):
            cell = entry["tiers"].get(tier)
            if cell is None:
                continue
            gates = cell["gates"]
            verdict = (
                "ok"
                if gates["fit"]
                else f"parse={gates['parse_rate']} bad_refs={gates['refs_bad']} "
                f"lang={gates['lang_rate']}"
            )
            lines.append(
                f"{variant:<16} {tier:<9} "
                f"{_num(cell['pps']):>6} "
                f"{_pct(cell['quality']):>5} {_pct(cell['reliability']):>5} "
                f"{_pct(cell['efficiency']):>5} {_pct(cell['simplicity']):>5} "
                f"{cell['median_gen_tokens']:>5.0f} {verdict:>26}"
            )
        flag = " TIER-FRAGILE" if entry.get("tier_fragile") else ""
        lines.append(f"{'':<16} {'headline':<9} {_num(entry['headline']):>6}{flag}\n")
    return "\n".join(lines)


def _pct(value: float | None) -> str:
    return "—" if value is None else f"{value:.2f}"


def _num(value: float | None) -> str:
    return "unfit" if value is None else f"{value:.1f}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--markdown", action="store_true", help="also write a leaderboard fragment")
    args = ap.parse_args()

    import sys

    sys.path.insert(0, str(HERE))
    result = summarize(args.tag, args.target)
    out_path = RESULTS / args.tag / f"scores.{args.target}.json"
    out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(table(result))  # noqa: T201 — research script
    print(f"-> {out_path}")  # noqa: T201

    if args.markdown:
        fragment = RESULTS / args.tag / f"leaderboard.{args.target}.md"
        fragment.write_text(_markdown(result))
        print(f"-> {fragment}")  # noqa: T201


def _markdown(result: dict[str, Any]) -> str:
    rows = ["| variant | PPS | quality | reliability | efficiency | simplicity | chars | notes |",
            "|---|---:|---:|---:|---:|---:|---:|---|"]
    order = sorted(
        result["variants"].items(),
        key=lambda kv: (kv[1]["headline"] is None, -(kv[1]["headline"] or 0)),
    )
    for variant, entry in order:
        cell = entry["tiers"].get("balanced", {})
        notes = []
        if entry.get("unfit_on"):
            notes.append("gate failed on " + ", ".join(entry["unfit_on"]))
        if entry.get("tier_fragile"):
            notes.append("tier-fragile")
        rows.append(
            f"| `{variant}` | {entry['headline'] if entry['headline'] is not None else '—'} | "
            f"{_pct(cell.get('quality'))} | {_pct(cell.get('reliability'))} | "
            f"{_pct(cell.get('efficiency'))} | {_pct(cell.get('simplicity'))} | "
            f"{entry['system_chars']} | {'; '.join(notes) or '—'} |"
        )
    return "\n".join(rows) + "\n"


if __name__ == "__main__":
    main()
