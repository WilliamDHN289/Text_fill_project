"""Leave-one-out ablation of PFM and identity baselines.

Each variant is a config override of `pfm`, so construction-side switches
(field weights, admission) rebuild the store. Identity baselines wrap the
full PFM ranker (and validity-filtered BM25) with a participant hard filter
or a relative score cutoff.
"""

from __future__ import annotations

import arms as A
import common as C
import metrics as M


def run(cfg: dict, out) -> dict:
    r, acfg = cfg["pfm"]["retrieval"], cfg["ablation"]
    rows = []
    for seed in cfg["benchmark"]["seeds"]:
        bench = C.make_bench(cfg, seed, acfg["corpus"])
        for name, override in acfg["variants"].items():
            store = C.build_store(C.merged(cfg["pfm"], override), bench)
            rows += C.evaluate(A.PFMArm(store, name), bench, r["k"], r["budget"],
                               seed=seed, family="ablation")
        rows += C.evaluate(A.PFMArm(C.build_store(cfg["pfm"], bench, keyed=False), "no_keys"),
                           bench, r["k"], r["budget"], seed=seed, family="ablation")
        store = C.build_store(cfg["pfm"], bench)
        full, bm25_v = A.PFMArm(store), A.BM25Arm(store, valid_only=True, participants=True)
        identity = [A.ParticipantFilter(full), A.ParticipantFilter(bm25_v)]
        identity += [A.RelativeCutoff(full, tau) for tau in acfg["cutoffs"]]
        for arm in identity:
            rows += C.evaluate(arm, bench, r["k"], r["budget"], seed=seed, family="identity")
    M.write_jsonl(out / "ablation.jsonl", rows)
    summary = {name: M.summarize(rs, ("all", "ambiguous", "unambiguous", "revised"), ci=False)
               for (name,), rs in M.group(rows, "arm").items()}
    C.write_json(out / "ablation.json", summary)
    return summary
