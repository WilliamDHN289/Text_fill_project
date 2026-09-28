#!/usr/bin/env python3
"""Render the long-term DPHM simulation (results/longterm_sim.json) as PNGs.

Design notes (dataviz method):
- color follows the entity everywhere: base llama = neutral ink gray
  (a reference line, not a competing series), DPHM = blue #2a78d6
  (categorical slot 1 of the validated reference palette); the probe chart
  uses slots 1/3 (blue/yellow, adjacent ΔE > 12, CVD-safe per palette.md)
- one axis per plot: different scales -> separate panels, never dual axes
- thin marks, hairline grid, muted axis ink, direct labels + legend

Usage: python3 visualize.py [--in results/longterm_sim.json] [--outdir results/figures]
"""

from __future__ import annotations

import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

# ---- palette (reference instance, light surface) ---------------------------
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"
BLUE = "#2a78d6"       # DPHM (series entity, all figures)
BLUE_200 = "#9ec5f4"
YELLOW = "#eda100"     # 'habit' source
RED = "#e34948"        # diverging negative pole
GRAY_SERIES = INK2     # base llama (reference entity, all figures)

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "font.size": 10,
    "axes.edgecolor": BASELINE, "axes.labelcolor": INK2,
    "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.titlecolor": INK, "font.family": "sans-serif",
})


def style(ax, grid_axis="y"):
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.7)
    ax.set_axisbelow(True)


def rolling(xs, w=3):
    out = []
    for i in range(len(xs)):
        lo = max(0, i - w + 1)
        out.append(sum(xs[lo:i + 1]) / (i - lo + 1))
    return out


def end_label(ax, x, y, text, color, dy=0):
    ax.annotate(text, (x, y), xytext=(6, dy), textcoords="offset points",
                color=color, fontsize=9.5, fontweight="bold", va="center")


def save(fig, outdir, name):
    path = os.path.join(outdir, name)
    fig.savefig(path, dpi=160, bbox_inches="tight")
    plt.close(fig)
    print(f"[viz] {path}")


# ---------------------------------------------------------------------------

def fig_accuracy(S, outdir):
    days = [s["day"] for s in S]
    fig, axes = plt.subplots(1, 2, figsize=(11, 4), sharey=True)
    for ax, k, title in ((axes[0], "top1", "Next-word accuracy — top-1"),
                         (axes[1], "top3", "Next-word accuracy — top-3")):
        for mode, color in (("base", GRAY_SERIES), ("dphm", BLUE)):
            ys = [s[f"{mode}_{k}"] for s in S]
            ax.plot(days, ys, color=color, linewidth=0.9, alpha=0.30)
            sm = rolling(ys)
            ax.plot(days, sm, color=color, linewidth=2.0,
                    label={"base": "base llama", "dphm": "llama + DPHM"}[mode])
            end_label(ax, days[-1], sm[-1], f"{sm[-1]:.0f}%", color,
                      dy=5 if mode == "dphm" else -5)
        style(ax)
        ax.set_title(title, loc="left", fontsize=11)
        ax.set_xlabel("session (virtual day)")
    ymax = max(max(s[f"{m}_{k}"] for s in S for m in ("base", "dphm"))
               for k in ("top1", "top3"))
    axes[0].set_ylim(0, ymax + 6)
    axes[0].set_ylabel("% of cut points hit")
    axes[0].legend(frameon=False, loc="upper left", fontsize=9)
    fig.suptitle("A month of daily writing, base llama vs llama + personal memory "
                 "(thin = raw, bold = 3-session mean)",
                 x=0.01, ha="left", fontsize=9.5, color=INK2, y=1.02)
    save(fig, outdir, "fig1_accuracy_over_sessions.png")


def fig_savings(S, outdir):
    days = [s["day"] for s in S]
    fig, ax = plt.subplots(figsize=(7.5, 4))
    for mode, color in (("base", GRAY_SERIES), ("dphm", BLUE)):
        ys = [s[f"cum_{mode}_saved"] for s in S]
        ax.plot(days, ys, color=color, linewidth=2.0,
                label={"base": "base llama", "dphm": "llama + DPHM"}[mode])
        end_label(ax, days[-1], ys[-1], f"{ys[-1]:,} ch", color,
                  dy=7 if mode == "dphm" else -7)
    style(ax)
    ax.set_title("Cumulative keystrokes saved by accepted top-1 suggestions",
                 loc="left", fontsize=11)
    ax.set_xlabel("session (virtual day)")
    ax.set_ylabel("characters")
    ax.legend(frameon=False, loc="upper left", fontsize=9)
    save(fig, outdir, "fig2_keystrokes_saved.png")


def fig_memory(S, outdir):
    days = [s["day"] for s in S]
    fig, axes = plt.subplots(2, 1, figsize=(7.5, 5.6), sharex=True,
                             gridspec_kw={"hspace": 0.35})
    ax = axes[0]
    ax.plot(days, [s["trie_contexts"] for s in S], color=BLUE, linewidth=2.0)
    end_label(ax, days[-1], S[-1]["trie_contexts"], f"{S[-1]['trie_contexts']:,}", BLUE)
    for s in S:
        if s.get("pruned"):
            ax.axvline(s["day"], color=GRID, linewidth=0.7, zorder=0)
    style(ax)
    ax.set_title("Long-term n-gram memory — contexts stored "
                 "(vertical hairlines: decay-prune runs)", loc="left", fontsize=11)
    ax.set_ylabel("contexts")

    ax = axes[1]
    ax.bar(days, [s["new_habits"] for s in S], color=BLUE_200,
           width=0.72, label="newly promoted this session")
    ax.plot(days, [s["habits"] for s in S], color=BLUE, linewidth=2.0,
            label="habit lexicon size")
    end_label(ax, days[-1], S[-1]["habits"], str(S[-1]["habits"]), BLUE)
    style(ax)
    ax.set_title("Consolidated habits (decayed count × PMI promotion)",
                 loc="left", fontsize=11)
    ax.set_xlabel("session (virtual day)")
    ax.set_ylabel("habits")
    ax.legend(frameon=False, loc="upper left", fontsize=9)
    save(fig, outdir, "fig3_memory_growth.png")


def fig_latency(data, outdir):
    o = data["overall"]
    S = data["sessions"]
    rows = [
        ("llama.cpp logprobs call  (p50)", o.get("llama_ms_p50") or 0, GRAY_SERIES),
        ("DPHM hot path  (p99)", o.get("dphm_ms_p99") or 0, BLUE),
        ("DPHM hot path  (p50)",
         sorted(s["dphm_ms_p50"] for s in S)[len(S) // 2], BLUE),
    ]
    rows = [r for r in rows if r[1]]
    fig, ax = plt.subplots(figsize=(7.5, 2.6))
    ys = range(len(rows))
    ax.barh(list(ys), [r[1] for r in rows], color=[r[2] for r in rows], height=0.55)
    for y, (_label, v, c) in zip(ys, rows):
        ax.annotate(f"{v:g} ms", (v, y), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=9.5, fontweight="bold", color=c)
    ax.set_yticks(list(ys), [r[0] for r in rows], color=INK2)
    ax.set_xscale("log")
    style(ax, grid_axis="x")
    ratio = rows[-1][1] / rows[0][1] if rows[0][1] else 0
    ax.set_title(f"Per-keystroke cost (log scale): the memory layer is ~{ratio:,.0f}× "
                 "cheaper than one LLM call", loc="left", fontsize=11)
    ax.set_xlabel("milliseconds")
    save(fig, outdir, "fig4_latency.png")


def fig_probes(data, outdir):
    """Timeline lanes: per probe prefix, the top-1 memory suggestion per
    session; segment color = source (blue ngram / yellow habit)."""
    S = data["sessions"]
    probes = data["probes"]
    days = [s["day"] for s in S]
    src_fill = {"ngram": BLUE_200, "habit": "#fadd9c", None: SURFACE}
    src_edge = {"ngram": BLUE, "habit": YELLOW, None: GRID}

    fig, ax = plt.subplots(figsize=(11.5, 0.62 * len(probes) + 1.6))
    for pi, probe in enumerate(probes):
        y = len(probes) - 1 - pi
        # group consecutive sessions with the same top-1 word
        segs = []
        for s in S:
            picks = s["probes"].get(probe) or []
            word, src = (picks[0][0], picks[0][1]) if picks else ("", None)
            if segs and segs[-1][0] == word and segs[-1][1] == src:
                segs[-1][3] = s["day"]
            else:
                segs.append([word, src, s["day"], s["day"]])
        for word, src, d0, d1 in segs:
            ax.add_patch(Rectangle((d0 - 0.5, y - 0.32), d1 - d0 + 1, 0.64,
                                   facecolor=src_fill[src], edgecolor=SURFACE,
                                   linewidth=1.5))
            if word:
                wide = d1 - d0 >= 1
                shown = word if wide or len(word) <= 5 else word[:4] + "…"
                ax.annotate(shown, ((d0 + d1) / 2, y), ha="center", va="center",
                            fontsize=8.5 if wide else 6.8, color=INK,
                            fontweight="bold" if src == "habit" else "normal")
        ax.annotate(f'"{probe.strip()} …"', (-1.2, y), ha="right", va="center",
                    fontsize=9, color=INK2)
    ax.set_xlim(-11, days[-1] + 1.5)
    ax.set_ylim(-0.6, len(probes) - 0.4)
    ax.set_yticks([])
    ax.set_xticks([d for d in days if d % 2 == 0])
    ax.spines[["top", "right", "left"]].set_visible(False)
    ax.set_xlabel("session (virtual day)")
    ax.set_title("What the memory suggests after fixed probe prefixes — "
                 "watch suggestions appear and stabilize", loc="left", fontsize=11)
    handles = [Rectangle((0, 0), 1, 1, facecolor=src_fill["ngram"], edgecolor=src_edge["ngram"]),
               Rectangle((0, 0), 1, 1, facecolor=src_fill["habit"], edgecolor=src_edge["habit"])]
    ax.legend(handles, ["personal n-gram", "consolidated habit"],
              frameon=False, loc="upper left", bbox_to_anchor=(0, -0.18),
              ncols=2, fontsize=9)
    save(fig, outdir, "fig5_probe_evolution.png")


def fig_delta(S, outdir):
    days = [s["day"] for s in S]
    deltas = [s["dphm_top1"] - s["base_top1"] for s in S]
    fig, ax = plt.subplots(figsize=(9, 3.6))
    ax.bar(days, deltas, color=[BLUE if d >= 0 else RED for d in deltas], width=0.72)
    ax.axhline(0, color=BASELINE, linewidth=1)
    sm = rolling(deltas, 5)
    ax.plot(days, sm, color=INK, linewidth=1.4)
    end_label(ax, days[-1], sm[-1], f"{sm[-1]:+.1f}pp", INK)
    style(ax)
    ax.set_title("DPHM advantage per session (top-1 accuracy, dphm − base; "
                 "line = 5-session mean)", loc="left", fontsize=11)
    ax.set_xlabel("session (virtual day)")
    ax.set_ylabel("percentage points")
    save(fig, outdir, "fig6_dphm_delta.png")


def fig_register(S, outdir):
    days = [s["day"] for s in S]
    fig, axes = plt.subplots(1, 2, figsize=(11, 4), sharey=True)
    for ax, reg, title in ((axes[0], "email", "Work email (Enron author)"),
                           (axes[1], "prose", "Long-form prose (Gutenberg)")):
        for mode, color in (("base", GRAY_SERIES), ("dphm", BLUE)):
            ys = rolling([s[f"{reg}_{mode}_top1"] for s in S])
            ax.plot(days, ys, color=color, linewidth=2.0,
                    label={"base": "base llama", "dphm": "llama + DPHM"}[mode])
            end_label(ax, days[-1], ys[-1], f"{ys[-1]:.0f}%", color,
                      dy=5 if mode == "dphm" else -5)
        style(ax)
        ax.set_title(title, loc="left", fontsize=11)
        ax.set_xlabel("session (virtual day)")
    ymax = max(max(rolling([s[f"{r}_{m}_top1"] for s in S]))
               for r in ("email", "prose") for m in ("base", "dphm"))
    axes[0].set_ylim(0, ymax + 6)
    axes[0].set_ylabel("top-1 accuracy, 3-session mean (%)")
    axes[0].legend(frameon=False, loc="upper left", fontsize=9)
    fig.suptitle("Top-1 accuracy by register: memory wins live on repeated "
                 "names and phrases in both",
                 x=0.01, ha="left", fontsize=9.5, color=INK2, y=1.02)
    save(fig, outdir, "fig7_register_breakdown.png")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "results", "longterm_sim.json"))
    ap.add_argument("--outdir", default=None)
    args = ap.parse_args()
    outdir = args.outdir or os.path.join(os.path.dirname(args.inp), "figures")
    os.makedirs(outdir, exist_ok=True)

    with open(args.inp) as f:
        data = json.load(f)
    S = data["sessions"]

    fig_accuracy(S, outdir)
    fig_savings(S, outdir)
    fig_memory(S, outdir)
    fig_latency(data, outdir)
    fig_probes(data, outdir)
    fig_delta(S, outdir)
    fig_register(S, outdir)
    print(f"[viz] done -> {outdir}")


if __name__ == "__main__":
    main()
