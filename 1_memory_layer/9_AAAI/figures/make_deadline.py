"""Figure 2 (fig:deadline): clean-correct fact by serving deadline.

Single-panel deadline curve from the authoritative study-6 run
(results/20260728-120901/study6.json), matching Table tab:baselines.
Vector PDF for LaTeX + a PNG preview.

Design follows the dataviz skill: the validated categorical palette in fixed
slot order, distinct markers as a colourblind-safe secondary encoding, a log
x-axis over the measured deadlines, recessive grid/axes, and a legend so
identity is never colour-alone. A light vertical guide marks the local dense
retriever's query-encoding cost (p50 15.4 ms).
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FIG = "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/figures"

DEADLINES = [0.5, 1, 2, 5, 10, 20]                      # ms
CURVES = {
    "pfm_full":      [0.875]*6,
    "pfm_snapshot":  [0.875]*6,
    "temporal_bm25": [0.7583]*6,
    "bm25_recency":  [0.2125]*6,
    "bm25_plain":    [0.1875]*6,
    "dense":         [0.0, 0.0, 0.0, 0.0, 0.0, 0.15],
    "hybrid_rrf":    [0.0, 0.0, 0.0, 0.0, 0.0, 0.175],
}
DENSE_ENCODE_MS = 15.4                                  # MiniLM query encode p50

# dataviz validated light-mode palette, fixed slot order.
SERIES = [   # name, colour, marker, label
    ("pfm_full",      "#2a78d6", "o", "PFM (fresh)"),
    ("temporal_bm25", "#008300", "s", "BM25 + validity filter"),
    ("bm25_recency",  "#e87ba4", "^", "BM25 + recency"),
    ("bm25_plain",    "#eda100", "D", "BM25"),
    ("dense",         "#1baf7a", "v", "Dense (MiniLM)"),
    ("hybrid_rrf",    "#eb6834", "P", "Hybrid (RRF)"),
]
SNAPSHOT_GREY = "#6a6a6a"

plt.rcParams.update({
    "font.family": "DejaVu Sans", "text.color": "black",
    "axes.edgecolor": "#444444", "axes.labelcolor": "black",
    "xtick.color": "black", "ytick.color": "black",
})

fig, ax = plt.subplots(figsize=(3.4, 2.75))

# encoding wall for the dense/hybrid arms
ax.axvline(DENSE_ENCODE_MS, color="#bcbcbc", lw=1.0, ls=(0, (2, 2)), zorder=1)
ax.text(DENSE_ENCODE_MS * 0.94, 0.30, "MiniLM query\nencode 15.4 ms",
        fontsize=6.2, color="#8a8a8a", ha="right", va="center", zorder=2,
        linespacing=1.05)

# snapshot: deadline-independent by construction, coincides with PFM (fresh)
ax.plot(DEADLINES, CURVES["pfm_snapshot"], color=SNAPSHOT_GREY, lw=3.4,
        ls=(0, (1, 1.6)), alpha=0.55, solid_capstyle="round",
        label="PFM (snapshot read)", zorder=3)

for name, colour, marker, label in SERIES:
    ax.plot(DEADLINES, CURVES[name], color=colour, lw=1.9, marker=marker,
            ms=5.0, mew=0.8, mfc=colour, mec="white", label=label,
            zorder=5 if name == "pfm_full" else 4)

ax.set_xscale("log")
ax.set_xticks(DEADLINES)
ax.set_xticklabels([f"{d:g}" for d in DEADLINES], fontsize=8)
ax.set_xlim(0.44, 23)
ax.set_ylim(-0.02, 1.0)
ax.set_yticks([0, 0.2, 0.4, 0.6, 0.8, 1.0])
ax.tick_params(axis="y", labelsize=8)
ax.set_xlabel("Serving deadline $\\Delta$ (ms, log scale)", fontsize=9)
ax.set_ylabel("Clean-correct fact by deadline", fontsize=9)

ax.grid(True, which="major", color="#e4e4e4", lw=0.6, zorder=0)
ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)

# direct labels for the two well-separated top lines, legend for the rest
ax.text(20.6, 0.875, ".88", fontsize=7.5, color="#2a78d6", va="center",
        fontweight="bold")
ax.text(20.6, 0.758, ".76", fontsize=7.5, color="#008300", va="center",
        fontweight="bold")

ax.legend(fontsize=6.2, frameon=False, loc="center left",
          bbox_to_anchor=(0.02, 0.45), handlelength=1.9, labelspacing=0.28,
          borderaxespad=0.0)

fig.tight_layout(pad=0.3)
fig.savefig(f"{FIG}/deadline_curve.pdf")
fig.savefig(f"{FIG}/deadline_curve_preview.png", dpi=200)
plt.close(fig)
print("deadline_curve.pdf + deadline_curve_preview.png written (single panel)")
