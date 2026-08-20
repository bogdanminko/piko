"""Generate the Pareto scatter (WER vs speed) for bench/asr/README.md.

Static SVG (GitHub markdown has no JS), light + dark variants, embedded via a
<picture> element so the reader's OS/GitHub theme picks the right one. Colors
and mark specs follow the dataviz skill's reference palette (categorical slots
1-3, since a scatter plot's series cap is 3 under the all-pairs CVD rule).

Layout: full direct labels only for the points worth naming at a glance
(frontier, shipped picks, isolated outliers). The dense mid-cluster of
dominated turbo/parakeet-fp16 rows — 5 points inside one WER percentage point
of each other — gets plain unlabeled dots: a numbered-chip key was tried and
still collided (checked by rendering, the skill's "look at it" step); the
full per-row numbers already live in the table right above this chart, so the
chart's job here is just the shape (small dense cluster vs. the two frontier
outliers), not exact readout.

Usage: python make_pareto_svg.py   (writes pareto-light.svg, pareto-dark.svg)
"""

import math
import pathlib

# Label convention: "<model> @ <engine> · <dtype>" — every point names all
# three (model, dtype, inference/engine), never a bare engine name like
# "parakeet-mlx" standing in for the model.
# (label, family, WER%, sec/min, is_frontier, tag)
# tag: "default" | "alternative" | None
POINTS = [
    ("parakeet-tdt-v3 @ transcribe-rs · fp32", "parakeet", 4.6, 1.32, True, None),
    ("parakeet-tdt-v3 @ mlx-audio · bf16", "parakeet", 4.8, 0.32, True, None),
    ("parakeet-tdt-v3 @ parakeet-mlx · bf16", "parakeet", 4.9, 0.75, False, "default"),
    ("whisper-turbo @ mlx-whisper · fp16", "whisper", 4.8, 1.91, False, "alternative"),
    ("qwen3-asr-0.6b @ mlx-audio · 8bit", "other", 6.6, 1.05, False, None),
]
# nemotron-3.5-asr (11.1% WER) and whisper-tiny (65.0% WER) excluded from the
# plot — either one alone would nearly double Y_MAX and crush the competitive
# 4.6-6.6% cluster into a sliver; both are noted in the caption instead.
# Dominated mid-cluster: numbered chips, not full labels (see module docstring).
NUMBERED = [
    ("whisper-large-v3 @ mlx-whisper · 8bit", "whisper", 4.7, 3.94),
    ("whisper-turbo @ mlx-audio · fp16", "whisper", 4.8, 1.82),
    ("whisper-turbo @ transcribe-rs · fp16", "whisper", 5.0, 1.97),
    ("whisper-turbo @ whisper.cpp · fp16", "whisper", 5.3, 2.11),
    ("parakeet-tdt-v3 @ transcribe-rs · fp16", "parakeet", 4.6, 2.08),
]
# whisper-tiny (65.0% WER) excluded from the plot — would compress every other
# point into the bottom 6% of the chart; noted in the caption instead.

FAMILY_LABEL = {"parakeet": "Parakeet", "whisper": "Whisper-turbo", "other": "Other"}

W, H = 800, 580
PAD_L, PAD_R = 56, 26
TITLE_Y, LEGEND_Y = 24, 50
PLOT_TOP = 74
PLOT_H = 340
PLOT_BOTTOM = PLOT_TOP + PLOT_H
PLOT_W = W - PAD_L - PAD_R

X_MIN, X_MAX = 0.25, 4.5  # sec/min, log scale
Y_MIN, Y_MAX = 4.0, 7.0  # WER%, linear — nemotron/tiny excluded, see POINTS
X_TICKS = [0.25, 0.5, 1, 2, 4]
Y_TICKS = [4, 5, 6, 7]

COLORS = {
    "light": dict(
        surface="#fcfcfb",
        primary="#0b0b0b",
        secondary="#52514e",
        muted="#898781",
        grid="#e1e0d9",
        axis="#c3c2b7",
        chip_fill="#fcfcfb",
        parakeet="#2a78d6",
        whisper="#eb6834",
        other="#1baf7a",
        frontier_ring="#0b0b0b",
    ),
    "dark": dict(
        surface="#1a1a19",
        primary="#ffffff",
        secondary="#c3c2b7",
        muted="#898781",
        grid="#2c2c2a",
        axis="#383835",
        chip_fill="#1a1a19",
        parakeet="#3987e5",
        whisper="#d95926",
        other="#199e70",
        frontier_ring="#ffffff",
    ),
}


def x_pos(sec_per_min: float) -> float:
    lo, hi = math.log(X_MIN), math.log(X_MAX)
    return PAD_L + (math.log(sec_per_min) - lo) / (hi - lo) * PLOT_W


def y_pos(wer: float) -> float:
    return PLOT_TOP + (1 - (wer - Y_MIN) / (Y_MAX - Y_MIN)) * PLOT_H


# (dx, dy, anchor) — anchor "end" for labels near the right edge (nemotron)
# so the text grows leftward instead of overflowing the canvas.
LABEL_OFFSETS = {
    "parakeet-tdt-v3 @ mlx-audio · bf16": (11, -10, "start"),
    "qwen3-asr-0.6b @ mlx-audio · 8bit": (11, 4, "start"),
    "nemotron-3.5-asr @ mlx-audio · bf16": (-11, 4, "end"),
}

# The three points inside the dense mid-cluster (fp32 frontier, the shipped
# default, the shipped alternative) are close enough that in-place labels
# collide regardless of offset — stacked labels + leader lines into the clear
# band above the cluster (between qwen3-asr and the cluster itself).
LEADER_LABELS = {
    "parakeet-tdt-v3 @ parakeet-mlx · bf16": (206, 160),
    "parakeet-tdt-v3 @ transcribe-rs · fp32": (206, 178),
    "whisper-turbo @ mlx-whisper · fp16": (206, 196),
}


def render(mode: str) -> str:
    c = COLORS[mode]
    svg = []
    svg.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'font-family="system-ui,-apple-system,Segoe UI,sans-serif">'
    )
    svg.append(f'<rect width="{W}" height="{H}" fill="{c["surface"]}"/>')

    svg.append(
        f'<text x="{PAD_L}" y="{TITLE_Y}" font-size="15" font-weight="600" '
        f'fill="{c["primary"]}">Piko ASR bench — quality vs speed (piko-audio-bench, all 4 languages)</text>'
    )

    # legend (family colors)
    lx = PAD_L
    for i, fam in enumerate(["parakeet", "whisper", "other"]):
        gx = lx + i * 150
        svg.append(f'<circle cx="{gx}" cy="{LEGEND_Y - 4}" r="5" fill="{c[fam]}"/>')
        svg.append(
            f'<text x="{gx + 10}" y="{LEGEND_Y}" font-size="11.5" fill="{c["secondary"]}">{FAMILY_LABEL[fam]}</text>'
        )
    svg.append(
        f'<circle cx="{lx + 3 * 150}" cy="{LEGEND_Y - 4}" r="8" fill="none" stroke="{c["frontier_ring"]}" stroke-width="1.5"/>'
    )
    svg.append(f'<circle cx="{lx + 3 * 150}" cy="{LEGEND_Y - 4}" r="5" fill="{c["muted"]}"/>')
    svg.append(
        f'<text x="{lx + 3 * 150 + 13}" y="{LEGEND_Y}" font-size="11.5" fill="{c["secondary"]}">Pareto frontier</text>'
    )

    # gridlines + x ticks (log scale)
    for xt in X_TICKS:
        x = x_pos(xt)
        svg.append(
            f'<line x1="{x:.1f}" y1="{PLOT_TOP}" x2="{x:.1f}" y2="{PLOT_BOTTOM}" '
            f'stroke="{c["grid"]}" stroke-width="1"/>'
        )
        svg.append(
            f'<text x="{x:.1f}" y="{PLOT_BOTTOM + 18}" font-size="11" '
            f'text-anchor="middle" fill="{c["muted"]}">{xt:g}</text>'
        )
    svg.append(
        f'<text x="{PAD_L + PLOT_W / 2:.1f}" y="{PLOT_BOTTOM + 38}" font-size="11.5" '
        f'text-anchor="middle" fill="{c["secondary"]}">sec of compute per minute of audio (log scale) — further left is faster</text>'
    )

    # gridlines + y ticks (linear)
    for yt in Y_TICKS:
        y = y_pos(yt)
        svg.append(
            f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{PAD_L + PLOT_W}" y2="{y:.1f}" '
            f'stroke="{c["grid"]}" stroke-width="1"/>'
        )
        svg.append(
            f'<text x="{PAD_L - 10}" y="{y + 4:.1f}" font-size="11" '
            f'text-anchor="end" fill="{c["muted"]}">{yt:g}%</text>'
        )
    svg.append(
        f'<text x="16" y="{PLOT_TOP + PLOT_H / 2:.1f}" font-size="11.5" fill="{c["secondary"]}" '
        f'text-anchor="middle" transform="rotate(-90 16 {PLOT_TOP + PLOT_H / 2:.1f})">WER — lower is better</text>'
    )

    # axis baseline
    svg.append(
        f'<line x1="{PAD_L}" y1="{PLOT_BOTTOM}" x2="{PAD_L + PLOT_W}" y2="{PLOT_BOTTOM}" '
        f'stroke="{c["axis"]}" stroke-width="1.5"/>'
    )
    svg.append(
        f'<line x1="{PAD_L}" y1="{PLOT_TOP}" x2="{PAD_L}" y2="{PLOT_BOTTOM}" '
        f'stroke="{c["axis"]}" stroke-width="1.5"/>'
    )

    # Pareto-optimal zone: the step boundary of "beats or ties the best known
    # trade-off on both axes" — a proper stairstep, not a diagonal (a diagonal
    # would imply intermediate WER/speed combos are achievable; only the two
    # frontier points and the axis-aligned steps between them are). Shaded
    # region = everywhere at least as good as our best result on both axes;
    # nothing sits inside it besides the frontier points themselves.
    frontier_pts = sorted([p for p in POINTS if p[4]], key=lambda p: p[3])
    if len(frontier_pts) >= 2:
        fx0, fy0 = x_pos(frontier_pts[0][3]), y_pos(frontier_pts[0][2])
        fx1, fy1 = x_pos(frontier_pts[1][3]), y_pos(frontier_pts[1][2])
        right_edge = PAD_L + PLOT_W
        # step continues at the better (lower) WER all the way to the right
        # edge — cutting the zone off at fx1 would wrongly exclude "faster
        # than fx1, at least as accurate as fy1" from the dominated region.
        step = [(fx0, fy0), (fx1, fy0), (fx1, fy1), (right_edge, fy1)]
        zone = [(PAD_L, fy0), *step, (right_edge, PLOT_BOTTOM), (PAD_L, PLOT_BOTTOM)]
        zone_path = " ".join(f"{x:.1f},{y:.1f}" for x, y in zone)
        svg.append(f'<polygon points="{zone_path}" fill="{c["parakeet"]}" fill-opacity="0.07"/>')
        step_path = " ".join(f"{x:.1f},{y:.1f}" for x, y in step)
        svg.append(
            f'<polyline points="{step_path}" fill="none" stroke="{c["muted"]}" '
            f'stroke-width="1.5" stroke-dasharray="4 3"/>'
        )
        svg.append(
            f'<text x="{PAD_L + 8}" y="{PLOT_BOTTOM - 10:.1f}" font-size="10.5" font-style="italic" '
            f'fill="{c["muted"]}">Pareto-optimal zone — nothing beats these two on both axes</text>'
        )

    # dominated dense-cluster points — plain unlabeled dots, smaller and
    # partly transparent so they read as "cluster" without competing with
    # the labeled points; exact rows are in the table above the chart
    for label, family, wer, speed in NUMBERED:
        x, y = x_pos(speed), y_pos(wer)
        svg.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{c[family]}" fill-opacity="0.45"/>'
        )

    # fully-labeled points
    for label, family, wer, speed, frontier, tag in POINTS:
        x, y = x_pos(speed), y_pos(wer)
        color = c[family]
        r = 5.5
        if frontier:
            svg.append(
                f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r + 3.5}" fill="none" '
                f'stroke="{c["frontier_ring"]}" stroke-width="1.5"/>'
            )
        svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{color}"/>')
        if tag:
            svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r - 2.2}" fill="{c["surface"]}"/>')
        disp = label + ("  ★" if tag else "")
        if label in LEADER_LABELS:
            lx, ly = LEADER_LABELS[label]
            svg.append(
                f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{lx - 5}" y2="{ly - 3.5}" '
                f'stroke="{c["muted"]}" stroke-width="1"/>'
            )
            svg.append(
                f'<text x="{lx}" y="{ly:.1f}" font-size="11" text-anchor="start" '
                f'fill="{c["secondary"]}">{disp}</text>'
            )
        else:
            dx, dy, anchor = LABEL_OFFSETS.get(label, (11, 4, "start"))
            svg.append(
                f'<text x="{x + dx:.1f}" y="{y + dy:.1f}" font-size="11" text-anchor="{anchor}" '
                f'fill="{c["secondary"]}">{disp}</text>'
            )

    # caption (two lines, below x-axis title)
    svg.append(
        f'<text x="{PAD_L}" y="{PLOT_BOTTOM + 58}" font-size="10.5" '
        f'fill="{c["muted"]}">Ring = Pareto frontier (not beaten on WER and speed at once) · ★ = what Piko ships · faint dots = 5 dominated whisper/parakeet-fp16 runtime rows, see table above.</text>'
    )
    svg.append(
        f'<text x="{PAD_L}" y="{PLOT_BOTTOM + 74}" font-size="10.5" '
        f'fill="{c["muted"]}">Off-scale, not plotted: nemotron-3.5-asr (11.1% WER) and whisper-tiny (65.0% WER) — see the table for both full rows.</text>'
    )

    svg.append("</svg>")
    return "\n".join(svg)


if __name__ == "__main__":
    out_dir = pathlib.Path(__file__).parent
    (out_dir / "pareto-light.svg").write_text(render("light"))
    (out_dir / "pareto-dark.svg").write_text(render("dark"))
    print("wrote pareto-light.svg, pareto-dark.svg")
