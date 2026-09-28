"""Figure 2 (fig:pipeline): the PFM architecture, MemGPT-style.

Two dashed bands (construction path / serving path) with the two stores
(BM25F index, entity graph) as the interface between them. Vector PDF;
all text black, non-italic, bold titles. Text auto-shrinks to its box.

Outputs: pipeline.pdf (for LaTeX) + pipeline_preview.png (for eyeballing).
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Ellipse, Rectangle

FIG = "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/figures"
plt.rcParams["font.family"] = "DejaVu Sans"

GREY, ORANGE, YELLOW = "#EDEDED", "#FCDFAE", "#FDF0C4"
BLUE_L, BLUE, GREEN, PINK = "#D9E7FA", "#AECBF2", "#CBE6C3", "#F6CFEE"

FIG_W = 8.0
fig = plt.figure(figsize=(FIG_W, 3.6))
ax = fig.add_axes((0.004, 0.008, 0.992, 0.984))
ax.set_xlim(0, 100)
ax.set_ylim(0, 45)
ax.axis("off")

PT_PER_UNIT = FIG_W * 72 * 0.992 / 100.0     # data-unit -> points
TITLE_FS, SUB_FS, BAND_FS, LBL_FS = 7.6, 6.3, 8.4, 6.4


def fit(text, w_units, base, bold=True):
    """Shrink fontsize so `text` fits in w_units (rough DejaVu metrics)."""
    longest = max(text.split("\n"), key=len)
    est = len(longest) * (0.62 if bold else 0.56) * base
    avail = (w_units - 1.6) * PT_PER_UNIT
    return base if est <= avail else max(5.4, base * avail / est)


def box(x, y, w, h, title, sub=None, fc=GREY, z=3, base_fs=TITLE_FS):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0,rounding_size=0.7",
        linewidth=1.3, edgecolor="black", facecolor=fc, zorder=z))
    cx, cy = x + w / 2, y + h / 2
    tfs = fit(title, w, base_fs)
    if sub:
        ax.text(cx, cy + h * 0.18, title, ha="center", va="center",
                fontsize=tfs, fontweight="bold", zorder=z + 1)
        ax.text(cx, cy - h * 0.23, sub, ha="center", va="center",
                fontsize=fit(sub, w, SUB_FS, bold=False), zorder=z + 1)
    else:
        ax.text(cx, cy, title, ha="center", va="center", fontsize=tfs,
                fontweight="bold", zorder=z + 1)


def cylinder(x, y, w, h, title, sub=None, fc=BLUE, ry=1.4):
    cx = x + w / 2
    ax.add_patch(Ellipse((cx, y), w, 2 * ry, facecolor=fc, edgecolor="black",
                         lw=1.3, zorder=3))
    ax.add_patch(Rectangle((x, y), w, h, facecolor=fc, edgecolor="none",
                           zorder=4))
    ax.plot([x, x], [y, y + h], color="black", lw=1.3, zorder=5)
    ax.plot([x + w, x + w], [y, y + h], color="black", lw=1.3, zorder=5)
    ax.add_patch(Ellipse((cx, y + h), w, 2 * ry, facecolor=fc,
                         edgecolor="black", lw=1.3, zorder=6))
    ty = y + h / 2 - ry * 0.3
    ax.text(cx, ty + h * 0.20, title, ha="center", va="center",
            fontsize=fit(title, w, TITLE_FS), fontweight="bold", zorder=7)
    if sub:
        ax.text(cx, ty - h * 0.24, sub, ha="center", va="center",
                fontsize=fit(sub, w, SUB_FS, bold=False), zorder=7)


def arrow(p0, p1, rad=0.0, dashed=False, lw=1.5, z=2):
    ax.add_patch(FancyArrowPatch(
        p0, p1, arrowstyle="-|>", mutation_scale=10, lw=lw, color="black",
        linestyle=(0, (4, 2.4)) if dashed else "solid",
        connectionstyle=f"arc3,rad={rad}", shrinkA=1.2, shrinkB=1.2, zorder=z))


def band(x, y, w, h, label, fc):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
        linewidth=1.2, edgecolor="black", linestyle=(0, (5, 3)),
        facecolor=fc, zorder=1))
    ax.text(x + 1.6, y + h - 1.7, label, fontsize=BAND_FS, fontweight="bold",
            va="center", zorder=2)


def label(x, y, s, ha="center", boxed=False):
    kw = dict(fontsize=LBL_FS, fontweight="bold", ha=ha, va="center", zorder=8)
    if boxed:
        kw["bbox"] = dict(boxstyle="round,pad=0.22", fc="white", ec="none")
    ax.text(x, y, s, **kw)


# ======================= construction band (top) ==========================
band(1, 31, 98, 13.4,
     "Construction path  —  asynchronous, off the keystroke path", "#FFFDF6")

BY, BH = 32.6, 6.6
box(3.5, BY, 12,   BH, "Captured\ndocuments", None, GREY)
box(19,  BY, 16.5, BH, "Fact extraction", "rule / LLM extractor", ORANGE)
box(39.5, BY, 16.5, BH, "Dedup / reinforce", "Jaccard → heat bump", ORANGE)
box(60,  BY, 16.5, BH, "Slot supersession", "bitemporal close", YELLOW)
box(80.5, BY, 16,  BH, "Periodic pruning", "recency × (1+heat)", GREY)

ym = BY + BH / 2
arrow((15.5, ym), (19, ym))
arrow((35.5, ym), (39.5, ym))
arrow((56.5, ym), (60, ym))

# ============================ stores (middle) =============================
cylinder(23, 20, 21, 5.2, "BM25F index", "field-weighted lexical", BLUE)
cylinder(52, 20, 23, 5.2, "Entity graph", "decayed co-occurrence", GREEN)

arrow((47.75, BY), (33, 26.6))
arrow((68.25, BY), (64, 26.6))
label(50.5, 29.5, "index & graph updates", boxed=True)
arrow((88.5, BY), (75.6, 24.2), rad=-0.25, dashed=True, lw=1.2)
label(86.5, 28.2, "evict", boxed=True)

# ========================== serving band (bottom) =========================
band(1, 0.8, 98, 16.4,
     "Serving path  —  bounded & non-blocking (Prop. 1), deadline Δ",
     "#F4F8FE")

SY, SH = 4.4, 6.6
sm = SY + SH / 2
box(3.5, SY, 12,   SH, "Typing\ncontext", None, GREY)
box(18.5, SY, 15.5, SH, "Bounded query", "≤ 12 terms, IDF-pruned", BLUE_L)
box(37,  SY, 21,   SH, "Retrieve & rank", "BM25F × recency × heat + assoc", BLUE)
box(61.5, SY + 4.0, 15, 5.0, "Snapshot", "prefetched, O(1) read", PINK)
box(61.5, SY - 2.4, 15, 5.0, "Deadline race", "fresh ≤ Δ, else snapshot", PINK)
box(80,  SY, 16.5, SH, "[Relevant memory]", "prompt block ≤ B chars", "white")

arrow((15.5, sm), (18.5, sm))
arrow((34, sm), (37, sm))
arrow((58, sm + 1.1), (61.5, SY + 6.5))
arrow((58, sm - 1.1), (61.5, SY + 0.1))
label(59.8, sm - 2.6, "or", boxed=True)
arrow((76.5, SY + 6.5), (80, sm + 1.1))
arrow((76.5, SY + 0.1), (80, sm - 1.1))

# reads: stores -> retrieve & rank
arrow((33.5, 18.6), (44, SY + SH))
arrow((63.5, 18.6), (52, SY + SH))
label(52, 13.6, "pure in-memory reads — no embedding, no LLM call",
      boxed=True)

# =========================== feedback loop ================================
arrow((88, SY + SH), (75.7, 22.4), rad=-0.34, dashed=True, lw=1.4)
label(89.8, 15.4, "accepted completion:\nmark_used → heat", boxed=True)

fig.savefig(f"{FIG}/pipeline.pdf", bbox_inches="tight", pad_inches=0.04)
fig.savefig(f"{FIG}/pipeline_preview.png", dpi=170, bbox_inches="tight",
            pad_inches=0.04)
print("pipeline.pdf + pipeline_preview.png written")
