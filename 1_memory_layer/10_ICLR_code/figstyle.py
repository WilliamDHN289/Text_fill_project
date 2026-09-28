"""One visual system for every figure in the paper.

The figures are read at column width on paper, so the constraints are legibility
at that size and survival in grayscale: type large enough to read, a legend that
never sits on the data, a marker shape per series so colour is not the only
encoding, and recessive axes so the lines carry the figure.

Colours are the validated categorical palette; the order here is the order the
validator was run on, so the hues stay separable for colour-vision deficiency.
"""

from __future__ import annotations

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BLUE, ORANGE, AQUA, YELLOW, VIOLET, RED = (
    "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#4a3aa7", "#e34948")
INK, MUTED = "#0b0b0b", "#52514e"

RC = {
    "font.size": 9,
    "axes.labelsize": 9.5,
    "axes.titlesize": 9.5,
    "xtick.labelsize": 8.5,
    "ytick.labelsize": 8.5,
    "legend.fontsize": 8,
    "axes.labelcolor": INK,
    "axes.edgecolor": "#b9b8b4",
    "axes.linewidth": 0.7,
    "text.color": INK,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "xtick.major.size": 2.5,
    "ytick.major.size": 2.5,
    "lines.linewidth": 1.7,
    "lines.markersize": 4.0,
    "legend.frameon": False,
    "legend.handlelength": 1.9,
    "legend.columnspacing": 1.3,
    "legend.handletextpad": 0.55,
    "figure.dpi": 200,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.015,
    "pdf.fonttype": 42,
}


def use() -> None:
    """Apply the paper's style. Called by each figure before it draws."""
    plt.rcParams.update(RC)


def tidy(ax, grid: str = "y") -> None:
    """Recessive frame: no top or right spine, one faint grid behind the data."""
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.grid(axis=grid, color="#d8d7d3", lw=0.6, alpha=0.9)
    ax.set_axisbelow(True)


def legend_below(fig, handles, labels, ncol: int, y: float = -0.015) -> None:
    """The legend goes under the whole figure, where it can cover neither a line
    nor the axis label. `tight_layout` first so the axes and their labels own
    their space; the negative anchor then puts the legend outside the canvas,
    which the tight bounding box grows to include."""
    fig.tight_layout()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, y),
               ncol=ncol, borderaxespad=0.0)
