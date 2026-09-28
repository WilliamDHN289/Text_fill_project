"""Keyed vs keyless supersession (Table: temporal correctness).

Seeds x corpora x {keyed, keyless} x budgets. Also writes the benchmark
accounting: chain -> query mapping and query counts per slice and depth.
"""

from __future__ import annotations

from collections import Counter

import arms as A
import common as C
import metrics as M


def benchmark_counts(bench) -> dict:
    chains = M.group(({"chain": q.qid.rsplit("-q", 1)[0], **q.meta} for q in bench.queries),
                     "chain")
    return {"chains": len(chains), "queries": len(bench.queries),
            "messages": len(bench.messages),
            "queries_per_chain": dict(Counter(len(v) for v in chains.values())),
            "queries_by_slice": {s: sum(f(q.meta) for q in bench.queries)
                                 for s, f in M.SLICES.items()},
            "chains_by_depth": dict(Counter(v[0]["revisions"] for v in chains.values())),
            "ambiguous_chains": sum(v[0]["ambiguous"] for v in chains.values())}


def run(cfg: dict, out) -> dict:
    k = cfg["pfm"]["retrieval"]["k"]
    rows, counts = [], {}
    for seed in cfg["benchmark"]["seeds"]:
        for corpus in cfg["benchmark"]["fillers"]:
            bench = C.make_bench(cfg, seed, corpus)
            counts[bench.label] = benchmark_counts(bench)
            for keyed in (True, False):
                store = C.build_store(cfg["pfm"], bench, keyed=keyed)
                reach = C.reachable(store, bench.queries)
                arm = A.PFMArm(store, "keyed" if keyed else "keyless")
                for budget in cfg["temporal"]["budgets"]:
                    for r in C.evaluate(arm, bench, k, budget, seed=seed, corpus=corpus):
                        rows.append(dict(r, reachable=r["qid"] in reach))
    M.write_jsonl(out / "temporal.jsonl", rows)
    summary = {f"{a}/{c}/b{b}": M.summarize(rs, ("all", "ambiguous", "revised", "cancelled",
                                                  "verbatim"),
                                             metrics=M.METRICS + ("reachable",))
               for (a, c, b), rs in M.group(rows, "arm", "corpus", "budget").items()}
    C.write_json(out / "temporal.json", {"summary": summary, "benchmark": counts})
    return summary
