"""Tables, figures, and headline numbers from one results directory.

    python3.11 make_report.py results/<run>

Writes <run>/report/: one .tex file per table, PDF figures, numbers.json
(every number quoted in the text), and llm_audit.csv (a sheet for manual
checking of the containment judge).
"""

from __future__ import annotations

import csv
import json
import random
import statistics
import sys
from collections import Counter
from pathlib import Path

import metrics as M

NAMES = {"pfm": "PFM", "bm25": "BM25", "bm25_recency": "BM25 + recency",
         "bm25_validity": "BM25 + validity", "dense": "Dense (MiniLM)",
         "dense_validity": "Dense + validity", "hybrid": "Hybrid (RRF)",
         "hybrid_validity": "Hybrid + validity"}


def f3(x: float) -> str:
    """Three decimals, leading zero kept, so every rate in the paper reads alike."""
    return f"{x:.3f}" if x < 1 else "1.000"


def pooled_quality(quality: dict, tag: str) -> dict:
    """Sum the key-error counts of every seed that ran this assigner, then take
    precision and recall over the pool, so one seed cannot carry the number."""
    counts, confusions = Counter(), Counter()
    for key, q in quality.items():
        if key.rsplit("|", 1)[0] == tag:
            counts.update(q["errors"])
            confusions.update(q["slot_confusions"])
    tp, fn = counts["correct"], counts["missed"]
    fp = counts["spurious"] + counts["wrong_slot"] + counts["wrong_entity"] + counts["wrong_both"]
    return {"precision": tp / max(1, tp + fp), "recall": tp / max(1, tp + fn),
            "errors": dict(counts), "slot_confusions": dict(confusions.most_common())}


def ci(cell: dict, m: str) -> str:
    lo, hi = cell[f"{m}_ci"]
    return f"{f3(cell[m])} {{\\scriptsize({f3(lo)}, {f3(hi)})}}"


def ms(x) -> str:
    return "--" if x is None else f"{x:.2f}" if x < 10 else f"{x:.1f}"


def tabular(spec: str, header: list, rows: list) -> str:
    lines = [f"\\begin{{tabular}}{{@{{}}{spec}@{{}}}}", "\\toprule", " & ".join(header) + " \\\\",
             "\\midrule"] + [" & ".join(r) + " \\\\" if r != "mid" else "\\midrule" for r in rows]
    return "\n".join(lines + ["\\bottomrule", "\\end{tabular}"]) + "\n"


class Report:
    def __init__(self, run: Path):
        self.run, self.out = run, run / "report"
        self.out.mkdir(exist_ok=True)
        self.numbers: dict = {}

    def load(self, name: str):
        path = self.run / f"{name}.jsonl"
        return M.read_jsonl(path) if path.exists() else None

    def save(self, name: str, text: str) -> None:
        (self.out / f"{name}.tex").write_text(text)

    # -- temporal ------------------------------------------------------------
    def temporal(self):
        rows = self.load("temporal")
        if rows is None:
            return
        body = []
        for budget in (800, 240):
            for arm in ("keyed", "keyless"):
                sub = [r for r in rows if r["arm"] == arm and r["budget"] == budget
                       and r["corpus"] == "noisy"]
                c = M.summarize(sub, metrics=M.METRICS + ("reachable",))["all"]
                body.append([arm.capitalize(), str(budget)] + [ci(c, m) for m in
                            ("current", "stale", "wrong", "coinject", "clean")])
                self.numbers[f"temporal/{arm}/b{budget}"] = c
                lean = M.summarize([r for r in rows if r["arm"] == arm and r["budget"] == budget
                                    and r["corpus"] == "lean"], ci=False)["all"]
                self.numbers[f"temporal/{arm}/b{budget}/lean"] = lean
        self.save("tab_temporal", tabular("llrrrrr", ["Arm", "$B$", "Current", "Stale",
                                                        "Wrong-person", "Co-inj.", "Clean"], body))
        bench = json.loads((self.run / "temporal.json").read_text())["benchmark"]
        self.numbers["benchmark"] = bench
        cols = ["ambiguous", "revised", "cancelled", "verbatim", "paraphrased_query"] + \
            [f"depth{d}" for d in range(5)]
        body = [[label.split("-")[1], str(c["messages"]), str(c["queries"]),
                 str(c["ambiguous_chains"])] + [str(c["queries_by_slice"][k]) for k in cols]
                for label, c in bench.items() if label.startswith("noisy")]
        self.save("tab_counts", tabular("l" + "r" * (3 + len(cols)),
                                        ["Seed", "Msgs", "Queries", "Amb. chains", "Amb.", "Rev.",
                                         "Canc.", "Verb.", "Para."] +
                                        [f"$d{{=}}{d}$" for d in range(5)], body))
        keyed = [r for r in rows if r["arm"] == "keyed" and r["budget"] == 800
                 and r["corpus"] == "noisy"]
        self.numbers["temporal/keyed_wrong_breakdown"] = {
            "wrong_total": sum(r["wrong"] for r in keyed),
            "wrong_on_ambiguous": sum(r["wrong"] and r["ambiguous"] for r in keyed),
            "ambiguous_queries": sum(r["ambiguous"] for r in keyed),
            "wrong_with_current_rank1": sum(r["wrong"] and r["rank_current"] == 1 for r in keyed),
            "per_seed": dict(Counter(r["qid"].split("-")[1] for r in keyed if r["wrong"]))}

    # -- baselines -----------------------------------------------------------
    def baselines(self):
        rows, lat = self.load("baselines"), self.load("baselines_latency")
        if rows is None:
            return
        info = json.loads((self.run / "baselines.json").read_text())
        runs = M.group(lat, "arm")
        body, cells = [], {}
        order = ["pfm", "bm25_validity", "dense_validity", "hybrid_validity",
                 "bm25", "bm25_recency", "dense", "hybrid"]
        for name in order:
            for p in ("", "+P"):
                arm = name if name == "pfm" else name + p
                if name == "pfm" and p:
                    continue
                sub = [r for r in rows if r["arm"] == arm]
                c = M.summarize(sub, ("all", "ambiguous"))
                cells[arm] = c
                ts = [r["ms"] for r in runs.get((arm,), [])]
                lat_cells = [ms(M.percentile(ts, 50)), ms(M.percentile(ts, 99))]
                label = NAMES[name] + (" ($+P_t$)" if p else "")
                body.append([label, ci(c["all"], "clean"), f3(c["all"]["current"]),
                             f3(c["all"]["stale"]), f3(c["all"]["wrong"])] + lat_cells)
            if name == "hybrid_validity":
                body.append("mid")
        self.save("tab_baselines", tabular("lrrrrrr", ["Method", "Clean", "Current", "Stale",
                                                         "Wrong", "p50 (ms)", "p99 (ms)"], body))
        latency = {}
        for (arm,), rs in runs.items():
            ts = [r["ms"] for r in rs]
            enc = [r["encode_ms"] for r in rs if r["encode_ms"] is not None]
            latency[arm] = {"n_runs": len(ts), "p50": M.percentile(ts, 50),
                            "p95": M.percentile(ts, 95), "p99": M.percentile(ts, 99),
                            "max": max(ts), "encode_p50": M.percentile(enc, 50) if enc else None}
        self.numbers["baselines/cells"] = {a: c["all"] for a, c in cells.items()}
        self.numbers["baselines/ambiguous"] = {a: c.get("ambiguous") for a, c in cells.items()}
        self.numbers["baselines/latency"] = latency
        self.numbers["baselines/info"] = info
        best = max((a for a in cells if a != "pfm"), key=lambda a: cells[a]["all"]["clean"])
        by = M.group(rows, "arm")
        self.numbers["baselines/paired"] = {
            other: {m: M.paired_difference(by[("pfm",)], by[(other,)], m)
                    for m in ("clean", "current", "wrong", "stale")}
            for other in {best, "bm25_validity", "dense_validity", "dense_validity+P"}}
        self.numbers["baselines/strongest"] = best
        seeds = sorted({r["seed"] for r in rows})
        per_seed = {}
        for (arm, _), seed_rows in sorted(M.group(rows, "arm", "seed").items()):
            per_seed.setdefault(arm, []).append(M.summarize(seed_rows, ci=False)["all"]["clean"])
        body = [[NAMES.get(a.replace("+P", ""), a) + (" ($+P_t$)" if a.endswith("+P") else "")]
                + [f3(v) for v in per_seed[a]]
                + [f"{f3(cells[a]['all']['clean'])} $\\pm$ {statistics.stdev(per_seed[a]):.3f}"]
                for a in ("pfm", "bm25_validity", "bm25_validity+P", "dense_validity+P",
                          "hybrid_validity+P", "bm25+P", "dense+P")]
        self.save("tab_seeds", tabular("l" + "r" * (len(seeds) + 1),
                                       ["Method"] + [f"seed {x}" for x in seeds] +
                                       ["Mean $\\pm$ sd"], body))
        self.deadline_figure(rows, lat, info)

    def deadline_figure(self, rows, lat, info):
        import figstyle as F
        import matplotlib.pyplot as plt
        F.use()
        seed = info["primary_seed"]
        clean = {(r["arm"], r["qid"]): r["clean"] for r in rows if r["seed"] == seed}
        deadlines = [0.25, 0.5, 1, 2, 5, 10, 20, 50]
        # Every arm serves only active facts except the last; the caption says so,
        # which keeps "+ validity" out of four legend entries.
        series = [("pfm", "PFM", F.BLUE, "o"),
                  ("bm25_validity+P", "BM25", F.ORANGE, "s"),
                  ("dense_validity+P", "Dense", F.AQUA, "v"),
                  ("hybrid_validity+P", "Hybrid", F.VIOLET, "D"),
                  ("dense+P", "Dense, no validity", F.RED, "^")]
        fig, ax = plt.subplots(figsize=(3.5, 2.5))
        curves, handles = {}, []
        for arm, label, color, marker in series:
            rs = [r for r in lat if r["arm"] == arm]
            ys = [sum(clean[(arm, r["qid"])] and r["ms"] <= d for r in rs) / len(rs)
                  for d in deadlines]
            curves[arm] = ys
            handles += ax.plot(deadlines, ys, color=color, marker=marker, label=label)
        reads = [r["ms"] for r in lat if r["arm"] == "snapshot_read"]
        for arm, color in (("pfm", F.BLUE), ("dense_validity+P", F.AQUA)):
            flags = [c for (a, _), c in clean.items() if a == arm]
            rate = sum(flags) / len(flags)
            curves[f"{arm}/snapshot"] = [rate * sum(t <= d for t in reads) / len(reads)
                                         for d in deadlines]
            ax.plot(deadlines, curves[f"{arm}/snapshot"], color=color, ls=(0, (1, 1.6)), lw=1.5)
        handles.append(plt.Line2D([], [], color=F.MUTED, ls=(0, (1, 1.6)), lw=1.5,
                                  label="from a snapshot"))
        ax.set_xscale("log")
        ax.set_xlabel("Serving deadline (ms)")
        ax.set_ylabel("Clean by deadline")
        ax.set_ylim(-0.03, 1.0)
        F.tidy(ax)
        F.legend_below(fig, handles, [h.get_label() for h in handles], ncol=3)
        fig.savefig(self.out / "deadline_curve.pdf")
        plt.close(fig)
        self.numbers["baselines/deadline_curves"] = {"deadlines_ms": deadlines, **curves}

    # -- ablation ------------------------------------------------------------
    def ablation(self):
        rows = self.load("ablation")
        if rows is None:
            return
        by = M.group(rows, "arm")
        full = M.summarize(by[("full",)], ("all", "ambiguous"), ci=False)
        body, cells = [], {}
        for (name,), rs in by.items():
            c = M.summarize(rs, ("all", "ambiguous", "revised"))
            cells[name] = {s: c[s] for s in c}
            d = c["all"]["clean"] - full["all"]["clean"]
            paired = M.paired_difference(rs, by[("full",)], "clean")
            cells[name]["paired_vs_full"] = paired
            body.append([name.replace("_", " ").replace("|", " | "), ci(c["all"], "clean"),
                         f"{d:+.3f}", f3(c["all"]["current"]), f3(c["all"]["stale"]),
                         f3(c["all"]["wrong"]), f3(c["ambiguous"]["clean"]),
                         f3(c["ambiguous"]["wrong"])])
        self.save("tab_ablation", tabular("lrrrrrrr", ["Variant", "Clean", "$\\Delta$", "Current",
                                                         "Stale", "Wrong", "Amb. clean",
                                                         "Amb. wrong"], body))
        self.numbers["ablation"] = cells

    # -- key noise -----------------------------------------------------------
    def keynoise(self):
        rows = self.load("keynoise")
        if rows is None:
            return
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        grid = {k: M.summarize(v, metrics=M.METRICS + ("lost_current",), ci=False)["all"]
                for k, v in M.group(rows, "p_miss", "q_false").items()}
        self.numbers["keynoise"] = {f"p{p}/q{q}": c for (p, q), c in grid.items()}
        ps = sorted({p for p, _ in grid})
        qs = sorted({q for _, q in grid})
        body = [[f"{p:g}"] + [f"{f3(grid[(p, q)]['clean'])} / {f3(grid[(p, q)]['stale'])} / "
                              f"{f3(grid[(p, q)]['lost_current'])}" for q in qs] for p in ps]
        self.save("tab_keynoise", tabular("l" + "c" * len(qs),
                                          ["$p$ (rows), $q$ (columns)"] + [f"{q:g}" for q in qs], body))
        import figstyle as F
        F.use()
        fig, axes = plt.subplots(1, 2, figsize=(5.4, 2.3), sharey=True)
        marks = (("clean", F.INK, "o", "clean"), ("current", F.BLUE, "s", "current"),
                 ("stale", F.ORANGE, "v", "stale"), ("lost_current", F.YELLOW, "D",
                                                     "current lost"))
        for ax, xs, key, label in ((axes[0], ps, lambda x: (x, 0.0), "missed-merge rate $p$"),
                                   (axes[1], qs, lambda x: (0.0, x), "false-merge rate $q$")):
            handles = [ax.plot(xs, [grid[key(x)][m] for x in xs], marker=mk, color=c,
                               label=name)[0] for m, c, mk, name in marks]
            ax.set_xlabel(label)
            ax.set_ylim(-0.03, 1.03)
            F.tidy(ax)
        axes[0].set_ylabel("Rate")
        F.legend_below(fig, handles, [h.get_label() for h in handles], ncol=4)
        fig.savefig(self.out / "keynoise.pdf")
        plt.close(fig)

    # -- response level ------------------------------------------------------
    VERDICTS = ("correct", "mixed", "stale", "wrong", "other")
    LLM_LABELS = {"none": "None", "pfm": "PFM", "pfm_keyless": "PFM, keyless", "bm25": "BM25",
                  "bm25_latest": "BM25 + latest-value instruction",
                  "bm25_validity": "BM25 + validity", "dense_validity": "Dense + validity"}

    def llm(self):
        rows = self.load("llm")
        if rows is None:
            return
        import exp_llm
        for r in rows:                              # re-judge the logged completions
            r.setdefault("model", "unknown")
            r["logged_verdict"], r["verdict"] = r["verdict"], exp_llm.judge(r["completion"],
                                                                            r["labels"])
        rows = [r for r in rows if not r.get("condition")]   # slices have their own table
        models = list(dict.fromkeys(r["model"] for r in rows))
        cells = {}
        for i, model in enumerate(models):
            sub = [r for r in rows if r["model"] == model]
            cells[model] = self.llm_model(model, sub, primary=(i == 0))
        self.numbers["llm"] = cells
        self.numbers["llm/rejudged_changes"] = sum(r["verdict"] != r["logged_verdict"]
                                                   for r in rows)
        info = json.loads((self.run / "llm.json").read_text())
        self.numbers["llm/info"] = {k: info[k] for k in ("backend", "retrieval_during_generation")}
        self.llm_audit(rows)

    def llm_model(self, model: str, rows: list, primary: bool) -> dict:
        body, cell = [], {}
        for (arm,), rs in M.group(rows, "arm").items():
            n = len(rs)
            counts = Counter(r["verdict"] for r in rs)
            prompt = M.summarize(rs, ci=False)["all"]
            ttft = [r["ttft_ms"] for r in rs if r.get("ttft_ms")]
            chars = sum(r["block_chars"] for r in rs) / n
            cell[arm] = {"n": n, "counts": dict(counts),
                         "rates": {v: counts[v] / n for v in self.VERDICTS},
                         "wilson": {v: M.rate([{"x": r["verdict"] == v} for r in rs], "x")
                                    for v in self.VERDICTS},
                         "prompt": prompt, "block_chars": chars,
                         "ttft_p50": M.percentile(ttft, 50), "ttft_p95": M.percentile(ttft, 95),
                         "prefill_p50": M.percentile([r["prefill_ms"] for r in rs], 50),
                         "retrieval_p50": M.percentile([r["retrieval_ms"] for r in rs], 50),
                         "prompt_tokens_mean": sum(r["prompt_tokens"] or 0 for r in rs) / n}
            prompt_cells = (["--"] * 3 if arm == "none" else
                            [f3(prompt["current"]), f3(prompt["stale"]), f3(prompt["wrong"])])
            body.append([self.LLM_LABELS.get(arm, arm)] + prompt_cells
                        + [f3(counts[v] / n) for v in self.VERDICTS]
                        + [f"{chars:.0f}", f"{cell[arm]['ttft_p50']:.0f}"])
        self.save("tab_llm" if primary else f"tab_llm_{model.split(':')[0]}",
                  tabular("lrrrrrrrrrr",
                          ["Memory", "Curr.", "Stale", "Wrong", "Correct", "Mixed", "Stale",
                           "Wrong", "Other", "Chars", "TTFT"], body))
        by = M.group(({**r, "correct": r["verdict"] == "correct"} for r in rows), "arm")
        cell["paired_correct_vs_pfm"] = {
            other: M.paired_difference(by[("pfm",)], by[(other,)], "correct")
            for (other,) in by if other not in ("pfm", "none")}
        cell["exposure_to_generation"] = {
            arm: {"prompt_stale": sum(r["stale"] for r in rs),
                  "generated_stale": sum(r["stale"] and r["verdict"] == "stale" for r in rs),
                  "prompt_wrong": sum(r["wrong"] for r in rs),
                  "generated_wrong": sum(r["wrong"] and r["verdict"] == "wrong" for r in rs)}
            for (arm,), rs in M.group(rows, "arm").items()}
        return cell

    def llm_audit(self, rows: list) -> None:
        rng = random.Random(0)
        pool = [r for r in rows if r["arm"] != "none"]
        audit = rng.sample(pool, min(50, len(pool)))
        audit += [r for r in pool if r["verdict"] == "other" and r not in audit]
        with open(self.out / "llm_audit.csv", "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["qid", "model", "arm", "verdict", "current", "stale", "wrong",
                        "completion", "human_verdict"])
            for r in audit:
                lab = r["labels"]
                w.writerow([r["qid"], r["model"], r["arm"], r["verdict"], lab["current"],
                            "; ".join(lab["stale"]), "; ".join(lab["wrong"]), r["completion"], ""])

    # -- depth, slices, extractor, crossover ---------------------------------
    REVISION_PRIOR = {0: 0.70, 1: 0.18, 2: 0.07, 3: 0.03, 4: 0.02}   # a store of mostly
    # write-once facts, against the benchmark's revision-heavy mix

    def depth(self):
        temporal, baselines = self.load("temporal"), self.load("baselines")
        if temporal is None:
            return
        groups = {"PFM (keyed)": [r for r in temporal if r["arm"] == "keyed"
                                  and r["budget"] == 800 and r["corpus"] == "noisy"],
                  "PFM, keyless": [r for r in temporal if r["arm"] == "keyless"
                                   and r["budget"] == 800 and r["corpus"] == "noisy"]}
        for arm in ("bm25_validity+P", "dense_validity+P", "bm25+P"):
            if baselines:
                groups[NAMES[arm.replace("+P", "")] + " ($+P_t$)"] = [r for r in baselines
                                                                     if r["arm"] == arm]
        body, cells = [], {}
        for name, rs in groups.items():
            by_depth = {d: [r for r in rs if r["revisions"] == d] for d in range(5)}
            clean = {d: sum(r["clean"] for r in v) / len(v) for d, v in by_depth.items() if v}
            observed = sum(r["clean"] for r in rs) / len(rs)
            prior = sum(self.REVISION_PRIOR[d] * c for d, c in clean.items())
            cells[name] = {"by_depth": clean, "benchmark_mix": observed, "reweighted": prior}
            body.append([name] + [f3(clean[d]) for d in range(5)] + [f3(observed), f3(prior)])
        self.save("tab_depth", tabular("lrrrrrrr",
                                       ["Method"] + [f"$d{{=}}{d}$" for d in range(5)]
                                       + ["Benchmark mix", "Reweighted"], body))
        self.numbers["depth"] = {"cells": cells, "prior": self.REVISION_PRIOR}

    def slices(self):
        rows = self.load("slices")
        if rows is None:
            return
        cells = {}
        blocks = {"multi_valued": ("Two instances of one slot type", ("current", "clean")),
                  "reorder": ("Out-of-order arrival", ("current", "stale", "clean")),
                  "participants": ("Participant is not the subject", ("current", "wrong",
                                                                      "clean")),
                  "hard_identity": ("Hard name collisions and unanswerable queries",
                                    ("current", "wrong", "clean"))}
        body = []
        for slice_name, (title, metrics) in blocks.items():
            sub = [r for r in rows if r["slice_name"] == slice_name]
            if not sub:
                continue
            body.append("mid")
            body.append([f"\\emph{{{title}}}", "", "", "", "", ""])
            for (store, case), rs in M.group(sub, "store", "case").items():
                c = M.summarize(rs, ci=False)["all"]
                cells[f"{slice_name}/{store}/{case}"] = c
                label = store if case in ("all", slice_name) else f"{store}, {case}"
                body.append([label.replace("_", " ").replace("|", ", "), str(len(rs))]
                            + [f3(c[m]) for m in ("current", "stale", "wrong", "clean")])
        self.save("tab_slices", tabular("lrrrrr",
                                        ["Condition", "$n$", "Current", "Stale", "Wrong",
                                         "Clean"], body[1:]))
        self.numbers["slices"] = cells

    def extractor(self):
        rows = self.load("extractor")
        if rows is None:
            return
        info = json.loads((self.run / "extractor.json").read_text())
        models, metrics = info["models"], M.METRICS + ("lost_current",)
        paired = info["paired"]

        def cells(store, model):
            rs = [r for r in rows if r["store"] == store and r["model"] == model]
            return M.summarize(rs, ci=False, metrics=metrics)["all"] if rs else None

        def delta(tag):
            d = paired.get(tag)
            return ("--" if d is None else
                    f"{d['diff']:+.3f} {{\\scriptsize({d['ci'][0]:+.3f}, {d['ci'][1]:+.3f})}}")

        def line(label, store, model, qtag=None):
            c = cells(store, model)
            q = pooled_quality(info["key_quality"], qtag) if qtag else None
            return [label,
                    f3(q["precision"]) if q else "--", f3(q["recall"]) if q else "--",
                    f3(c["current"]), f3(c["stale"]), f3(c["clean"]), f3(c["lost_current"]),
                    delta(f"{store}|{model}") if store != "rule keys" else "--"]

        body = [line("rule keys", "rule keys", "rule", "rule keys")]
        body += [line(f"model keys, {m}", "model keys", m, f"model keys|{m}") for m in models]
        body.append("mid")
        body += [line(f"model updates, {m}$^\\dagger$", "model updates", m) for m in models]
        body.append(line("keyless", "keyless", "rule"))
        self.save("tab_extractor", tabular("lrrrrrrr",
                                           ["Construction", "Key prec.", "Key rec.", "Current",
                                            "Stale", "Clean", "Lost", "$\\Delta$ clean vs rule"],
                                           body))

        # The error taxonomy: how the keys are wrong, which is what decides the
        # ordering. A missed key shows up in the prompt; a wrong slot deletes.
        body = []
        for tag, label in [("rule keys", "rule keys")] + [(f"model keys|{m}", m) for m in models]:
            q = pooled_quality(info["key_quality"], tag)
            e = q["errors"]
            top = max(q["slot_confusions"].items(), key=lambda kv: kv[1], default=("--", 0))
            arrow = top[0].replace("->", " $\\to$ ")
            body.append([label, str(e.get("correct", 0)), str(e.get("missed", 0)),
                         str(e.get("wrong_slot", 0) + e.get("wrong_both", 0)),
                         str(e.get("wrong_entity", 0)), str(e.get("spurious", 0)),
                         f"{arrow} ({top[1]})" if top[1] else "--"])
        self.save("tab_key_errors", tabular("lrrrrrl",
                                            ["Key assigner", "Correct", "Missed", "Wrong slot",
                                             "Wrong entity", "Spurious", "Commonest confusion"],
                                            body))
        self.numbers["extractor"] = {
            **info,
            "pooled_quality": {t: pooled_quality(info["key_quality"], t)
                               for t in ["rule keys"] + [f"model keys|{m}" for m in models]},
            "cells": {f"{s}|{m}": M.summarize(rs, ci=False, metrics=metrics)["all"]
                      for (s, m), rs in M.group(rows, "store", "model").items()},
            "per_seed_clean": {f"{s}|{m}|{sd}": M.summarize(rs, ci=False)["all"]["clean"]
                               for (s, m, sd), rs in M.group(rows, "store", "model",
                                                             "seed").items()}}

    def crossover(self):
        path = self.run / "crossover.json"
        if not path.exists():
            return
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import figstyle as F
        F.use()
        rows = json.loads(path.read_text())["rows"]
        fig, ax = plt.subplots(figsize=(3.5, 2.5))
        names = list(dict.fromkeys(r["distribution"] for r in rows))
        # Colour carries the method and dash carries the term distribution, so the
        # legend names each once instead of naming all four combinations.
        styles = dict(zip(names, ("-", (0, (4, 1.8)), (0, (1, 1.6)))))
        for dist, ls in styles.items():
            sub = [r for r in rows if r["distribution"] == dist]
            if not sub:
                continue
            xs = [r["facts"] for r in sub]
            ax.plot(xs, [r["pfm_p50"] for r in sub], ls=ls, marker="o", color=F.BLUE)
            ax.plot(xs, [r["dense_p50"] for r in sub], ls=ls, marker="s", color=F.AQUA)
        handles = [plt.Line2D([], [], color=F.BLUE, marker="o", label="PFM"),
                   plt.Line2D([], [], color=F.AQUA, marker="s", label="Dense (MiniLM)")]
        handles += [plt.Line2D([], [], color=F.MUTED, ls=styles[n], label=n.replace(" vocabulary", " vocab."))
                    for n in names if any(r["distribution"] == n for r in rows)]
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlabel("Facts in the store")
        ax.set_ylabel("Retrieval p50 (ms)")
        F.tidy(ax, grid="both")
        F.legend_below(fig, handles, [h.get_label() for h in handles], ncol=2)
        fig.savefig(self.out / "crossover.pdf")
        plt.close(fig)
        cross = {}
        for dist in names:
            sub = [r for r in rows if r["distribution"] == dist]
            over = [r["facts"] for r in sub if r["pfm_p50"] > r["dense_p50"]]
            cross[dist] = min(over) if over else None
        self.numbers["crossover"] = {"rows": rows, "first_size_pfm_slower": cross}

    # -- serving and scaling -------------------------------------------------
    def serving(self):
        path = self.run / "serving.json"
        if not path.exists():
            return
        serving = json.loads(path.read_text())
        self.numbers["serving"] = serving
        body = [[str(int(lag[3:])), s_] + [f3(serving["lag"][lag][s_][m])
                                         for m in ("current", "stale", "clean")]
                for lag in serving["lag"] for s_ in ("revised", "unrevised")]
        self.save("tab_lag", tabular("llrrr", ["Lag", "Slice", "Current", "Stale", "Clean"], body))
        body = []
        for run in serving["load"]:
            row = ["on" if run["gc_enabled"] else "off"]
            for key in ("sigma_required_ms", "snapshot_read_ms", "fresh_ms"):
                if key in run:
                    row += [ms(run[key]["p50"]), ms(run[key]["p99"]), ms(run[key]["max"])]
                else:
                    row += ["--"] * 3
            body.append(row + [f3(run["fresh_fallback_rate"])])
        self.save("tab_load", tabular("l" + "r" * 10,
                                      ["GC", "$\\sigma$ p50", "p99", "max", "read p50", "p99",
                                       "max", "fresh p50", "p99", "max", "fallback"], body))
        parts = [r for r in serving["load"] if "fresh_parts_ms" in r]
        if parts:
            self.save("tab_waiting", tabular(
                "l" + "r" * 6,
                ["GC", "submit p50", "p99", "max", "sleep $\\sigma$ p50", "p99", "max"],
                [["on" if r["gc_enabled"] else "off"]
                 + [ms(r["fresh_parts_ms"]["submit"][k]) for k in ("p50", "p99", "max")]
                 + [ms(r["sleep_wakeup_ms"][k]) for k in ("p50", "p99", "max")]
                 for r in parts]))

    def scaling(self):
        path = self.run / "scaling.json"
        if not path.exists():
            return
        rows = json.loads(path.read_text())["rows"]
        body = [[f"{r['facts']:,}".replace(",", "{,}"), str(r["queries"]), ms(r["p50_ms"]),
                 ms(r["p99_ms"]), ms(r.get("frozen_p50_ms")), ms(r.get("frozen_p99_ms")),
                 f"{r['add_p50_ms']:.3f}", f"{r['traced_mb']:.1f}"] for r in rows]
        self.save("tab_scaling", tabular("rrrrrrrr", ["Facts", "Queries", "p50", "p99",
                                                        "p50 (frozen)", "p99 (frozen)",
                                                        "Add p50", "Heap (MB)"], body))
        self.numbers["scaling"] = rows

    # -- real corpora, identity, query-time model baselines -------------------
    def real(self):
        path = self.run / "real.json"
        if not path.exists():
            return
        real = json.loads(path.read_text())
        self.numbers["real"] = real
        lme = real["longmemeval"]["summary"]
        order = [a for a in lme if a.startswith("pfm (")] + \
                ["pfm, keyless", "bm25", "bm25_recency", "bm25_validity", "dense_validity"]
        body = [[NAMES.get(a, a), str(lme[a]["n"])]
                + [f3(lme[a][m]) for m in ("current", "stale", "coinject", "clean")]
                for a in order if a in lme]
        self.save("tab_lme", tabular("lrrrrr", ["Arm", "$n$", "Current", "Stale",
                                                "Co-injection", "Clean"], body))

        # Table 4's shape: the key diagnostics beside the retrieval outcome of the
        # store they produced. Merge recall is the merge supersession needs;
        # cross-question is the false merge that deletes.
        keys = real["longmemeval"]["info"]["keys"]
        models = list(dict.fromkeys(k.split("|")[1] for k in keys if "|" in k))
        pairs = []
        for m in models:
            for mode, label in (("stateless", "stateless"),
                                ("key-aware", "store in the extraction prompt"),
                                ("model-linked", "model-judged linking")):
                pairs.append((f"pfm ({mode}, {m})", f"{mode}|{m}", f"{label}, {m}"))
        pairs += [(f"pfm (linked @{t})", f"linked@{t}",
                   "\\quad linked at $\\theta{=}" + str(t) + "$")
                  for t in sorted({k.split("@")[1] for k in keys if k.startswith("linked@")},
                                  reverse=True)]
        pairs += [("pfm, keyless", None, "no update resolution"),
                  ("bm25", None, "BM25"), ("bm25_recency", None, "BM25 + recency")]
        body = []
        for arm, kkey, label in pairs:
            if arm not in lme:
                continue
            k = keys.get(kkey) if kkey else None
            body.append([label,
                         f3(k["both_turns_keyed"]) if k else "--",
                         f3(k["merge_given_both"]) if k else "--",
                         f3(k["merge_recall"]) if k else "--",
                         f3(k["cross_question_rate"]) if k else "--",
                         f3(lme[arm]["stale"]), f3(lme[arm]["clean"])])
        self.save("tab_lme_keys", tabular("lrrrrrr",
                                          ["Key assignment", "Both turns keyed",
                                           "Merged $\\mid$ both", "Merge recall",
                                           "Cross-question", "Stale", "Clean"], body))
        self.numbers["real/lme_keys"] = keys

        loc = real["locomo"]["summary"]
        off = real["locomo"]["info"]["off_conversation_fact_share"]
        body = [[NAMES.get(a, a), f3(loc[a]["all"]["wrong"]), f3(loc[a]["ambiguous"]["wrong"]),
                 f3(off.get(a, 0.0)), f3(loc[a]["all"]["current"])] for a in loc]
        self.save("tab_locomo", tabular("lrrrr",
                                        ["Arm", "Wrong person", "\\quad name-sharing",
                                         "Off-conversation lines", "Current"], body))
        abst = real["locomo"]["abstention_summary"]
        body = [[NAMES.get(a, a), f3(v["answerable"]["current"]), f3(v["answerable"]["abstain"]),
                 f3(v["unanswerable"]["abstain"])] for a, v in abst.items()]
        self.save("tab_real_abstain", tabular("lrrr",
                                              ["Arm", "Current (answerable)",
                                               "Abstained (answerable)",
                                               "Abstained (unanswerable)"], body))

    def llm_slices(self):
        """Response level on the broken-prompt conditions and under sampling."""
        rows = self.load("llm")
        rows = [r for r in (rows or []) if r.get("condition")]
        if not rows:
            return
        import exp_llm
        for r in rows:
            r["verdict"] = exp_llm.judge(r["completion"], r["labels"])
        body, cells = [], {}
        for (cond, model, arm), rs in M.group(rows, "condition", "model", "arm").items():
            n = len(rs)
            counts = Counter(r["verdict"] for r in rs)
            prompt = M.summarize(rs, ci=False)["all"]
            cells[f"{cond}/{model}/{arm}"] = {"n": n, "counts": dict(counts),
                                              "prompt": prompt}
            body.append([cond, model.split(":")[0], NAMES.get(arm, arm.replace("_", " ")),
                         str(n), f3(prompt["stale"]), f3(prompt["wrong"]),
                         f3(counts["correct"] / n), f3(counts["stale"] / n),
                         f3(counts["wrong"] / n)])
        body.sort()
        self.save("tab_llm_slices", tabular(
            "lllrrrrrr",
            ["Condition", "Model", "Memory", "$n$", "Prompt stale", "Prompt wrong",
             "Correct", "Stale", "Wrong"], body))
        self.numbers["llm_slices"] = cells

    def identity(self):
        path = self.run / "identity.json"
        if not path.exists():
            return
        ident = json.loads(path.read_text())
        self.numbers["identity"] = ident
        S = ident["summary"]
        keep = ["pfm", "pfm|cutoff@0.7", "pfm|participant_filter", "pfm|identity_hard",
                "pfm|identity_hard|abstain_slot@0.5", "pfm|abstain_margin@2.0"]
        body = []
        for arm in keep:
            main, hard = S.get(f"main/{arm}"), S.get(f"hard/{arm}")
            part = S.get(f"participants/{arm}")
            if not (main and hard and part):
                continue
            body.append([NAMES.get(arm, arm.replace("pfm|", "").replace("_", " ")),
                         f3(main["all"]["wrong"]), f3(main["all"]["clean"]),
                         f3(part["third_party"]["current"]),
                         f3(hard["answerable"]["clean"]),
                         f3(hard["unanswerable"]["abstain"]),
                         f3(main["all"]["abstain"])])
        self.save("tab_identity", tabular(
            "lrrrrrr",
            ["Serving rule", "Wrong", "Clean", "3rd-party recall", "Hard clean",
             "Abstained (no answer)", "Abstained (main)"], body))

    def systems(self):
        path = self.run / "systems.json"
        if not path.exists():
            return
        sysres = json.loads(path.read_text())
        self.numbers["systems"] = sysres
        S, cost = sysres["summary"], sysres["request_path_model_ms"]
        arms = sorted({k.split("/", 1)[1] for k in S})
        body = []
        for arm in arms:
            main, hard = S.get(f"main/{arm}"), S.get(f"hard/{arm}")
            if not (main and hard):
                continue
            body.append([arm.replace("pfm|", "").replace("bm25+P|", "").replace("_", " "),
                         f3(main["all"]["stale"]), f3(main["all"]["wrong"]),
                         f3(main["all"]["clean"]), f3(hard["unanswerable"]["abstain"]),
                         ms(cost[arm]["p50"]) if arm in cost else "--"])
        self.save("tab_systems", tabular(
            "lrrrrr", ["Arm", "Stale", "Wrong", "Clean", "Abstained (no answer)",
                       "Model ms p50"], body))

    def write(self):
        for step in (self.temporal, self.baselines, self.ablation, self.keynoise, self.llm,
                     self.depth, self.slices, self.extractor, self.crossover, self.serving,
                     self.scaling, self.real, self.identity, self.systems,
                     self.llm_slices):
            step()
        (self.out / "numbers.json").write_text(json.dumps(self.numbers, indent=1, default=list))
        print(f"report: {self.out}")


if __name__ == "__main__":
    Report(Path(sys.argv[1])).write()
