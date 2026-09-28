"""Study 6 — Retrieval baselines under a shared budget + quality-vs-deadline
(paper tasks 2 + 3).

Every arm ranks the same extracted facts on the same machine with the same
k / character budget (see retrievers.py). Per query we record clean-correct
(current fact present, no stale, no wrong-person value) and retrieval
latency (median of `n_latency_repeats` timed runs after a warmup pass).

Quality-vs-deadline: success@D = fraction of queries whose retrieval both
finished within D milliseconds AND produced a clean correct fact block.
`pfm_snapshot` models the deployed prefetched read: same ranking, zero
hot-path latency, so its curve is flat at the clean rate. The figure
(figures/deadline_curve.pdf) is intended as the paper's main figure.
"""

from __future__ import annotations

import statistics
import time
from typing import Dict, List

import benchmark as B
import common
import keyed_extractor as KE
import retrievers as R
import study5_temporal as S5

FIGDIR = common.EXP_DIR.parent / "figures"

# dataviz reference palette (light mode, fixed slot order; pre-validated —
# see skill references/palette.md). Neutral grey = snapshot reference line.
SERIES = [
    ("pfm_full",      "#2a78d6", "o", "PFM (fresh)"),
    ("temporal_bm25", "#008300", "s", "BM25 + validity filter"),
    ("bm25_recency",  "#e87ba4", "^", "BM25 + recency"),
    ("bm25_plain",    "#eda100", "D", "BM25"),
    ("dense",         "#1baf7a", "v", "Dense (MiniLM)"),
    ("hybrid_rrf",    "#eb6834", "P", "Hybrid (RRF)"),
]
SNAPSHOT_GREY = "#666666"


def run(cfg: dict, out_dir) -> dict:
    s6 = cfg["study6"]
    s5 = cfg["study5"]
    bench = B.generate(s5["n_chains"], s5["seed"],
                       s5["corpora"][s6["corpus"]], s5["p_cancel"],
                       {int(k): v for k, v in s5["rev_weights"].items()},
                       s6["corpus"])
    dcfg = dict(cfg["dpfm"], extraction={"gazetteer": bench.gazetteer})
    mem = common.build_memory(dcfg, bench.messages,
                              extractor=KE.make_keyed_extractor(bench.gazetteer),
                              cls=common.TemporalDPFM)
    k = cfg["dpfm"]["retrieval"]["k"]
    budget = s6["budget"]
    arm_names = [a for a in s6["arms"] if a != "pfm_snapshot"]
    arms, build_s = R.build_arms(arm_names, mem, cfg)

    per_arm: Dict[str, dict] = {}
    for arm in arms:
        # correctness pass (also warms caches)
        rows = []
        for q in bench.queries:
            block, _ = arm.retrieve(q.prefix, q.partner, k, budget, common.BASE)
            r = S5.eval_query(block, q)
            r["meta"] = q.meta
            rows.append(r)
        # timed passes
        lats: List[float] = []
        for q in bench.queries:
            samples = []
            for _ in range(s6["n_latency_repeats"]):
                t0 = time.perf_counter()
                arm.retrieve(q.prefix, q.partner, k, budget, common.BASE)
                samples.append((time.perf_counter() - t0) * 1000.0)
            lats.append(statistics.median(samples))
        per_arm[arm.name] = {
            "metrics": {m: S5._rate(rows, m)
                        for m in ("current", "stale", "wrong", "clean")},
            "latency": common.latency_summary(sorted(lats)),
            "build_s": build_s[arm.name],
            "backend": getattr(arm, "backend", None),
            "_rows": rows, "_lats": lats,
        }

    # deadline curves
    deadlines = s6["deadlines_ms"]
    curves: Dict[str, List[float]] = {}
    for name, data in per_arm.items():
        clean = [r["clean"] for r in data["_rows"]]
        curves[name] = [
            round(sum(c and l <= D for c, l in zip(clean, data["_lats"]))
                  / len(clean), 4) for D in deadlines]
    if "pfm_snapshot" in s6["arms"]:
        clean_rate = per_arm["pfm_full"]["metrics"]["clean"]["rate"]
        curves["pfm_snapshot"] = [round(clean_rate, 4)] * len(deadlines)
        per_arm["pfm_snapshot"] = {
            "metrics": per_arm["pfm_full"]["metrics"],
            "latency": {"n": 0, "p50_ms": 0.0, "p95_ms": 0.0, "max_ms": 0.0},
            "build_s": 0.0, "backend": "prefetched snapshot (O(1) read)",
        }

    _figure(deadlines, curves, s6)

    for data in per_arm.values():                       # strip bulky internals
        data.pop("_rows", None)
        data.pop("_lats", None)
    result = {
        "status": "DONE", "corpus": s6["corpus"],
        "n_queries": len(bench.queries), "budget": budget,
        "store": mem.stats(), "deadlines_ms": deadlines,
        "arms": per_arm, "curves": curves,
        "timing_boundary": ("wall time around arm.retrieve(): query "
                            "construction/encoding + scoring + ranking + "
                            "block formatting; median of "
                            f"{s6['n_latency_repeats']} runs after warmup; "
                            "single query at a time (batch=1)"),
    }
    common.write_json(out_dir / "study6.json", result)
    return result


def _figure(deadlines, curves, s6) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": "black",
                         "axes.edgecolor": "#444444",
                         "axes.labelcolor": "black",
                         "xtick.color": "black", "ytick.color": "black"})
    fig, ax = plt.subplots(figsize=(3.4, 2.75))

    if "pfm_snapshot" in curves:
        ax.plot(deadlines, curves["pfm_snapshot"], color=SNAPSHOT_GREY,
                lw=1.6, ls=(0, (4, 2.5)), label="PFM (snapshot read)",
                zorder=3)
    for name, color, marker, label in SERIES:
        if name not in curves:
            continue
        ax.plot(deadlines, curves[name], color=color, lw=1.8, marker=marker,
                ms=4.5, mew=0.8, mfc=color, mec="white", label=label,
                zorder=4 if name == "pfm_full" else 3)

    ax.set_xscale("log")
    ax.set_xticks(deadlines)
    ax.set_xticklabels([f"{d:g}" for d in deadlines], fontsize=7.5)
    ax.set_ylim(0, 1.02)
    ax.tick_params(axis="y", labelsize=7.5)
    ax.set_xlabel("Serving deadline Δ (ms, log scale)", fontsize=8.5)
    ax.set_ylabel("Clean-correct fact by deadline", fontsize=8.5)
    ax.grid(True, which="major", color="#dddddd", lw=0.6, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.legend(fontsize=6.6, frameon=False, loc="center right",
              handlelength=2.2, labelspacing=0.35)
    fig.tight_layout(pad=0.3)
    FIGDIR.mkdir(exist_ok=True)
    fig.savefig(FIGDIR / "deadline_curve.pdf")
    fig.savefig(FIGDIR / "deadline_curve_preview.png", dpi=170)
    plt.close(fig)


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 6: {r.get('status')}"
    lines = [f"Study 6 (baselines, corpus={r['corpus']}, "
             f"{r['n_queries']} queries, {r['store']['valid_facts']} valid facts):"]
    for name, d in r["arms"].items():
        m = d["metrics"]
        lines.append(
            f"  {name:14s} clean {m['clean']['rate']:.3f} "
            f"(cur {m['current']['rate']:.3f} stale {m['stale']['rate']:.3f} "
            f"wrong {m['wrong']['rate']:.3f}) "
            f"lat p50={d['latency']['p50_ms']}ms p95={d['latency']['p95_ms']}ms")
    lines.append("  success@D: " + "; ".join(
        f"{n}={c[0]:.2f}@{r['deadlines_ms'][0]}ms→{c[-1]:.2f}@{r['deadlines_ms'][-1]}ms"
        for n, c in r["curves"].items()))
    return "\n".join(lines)
