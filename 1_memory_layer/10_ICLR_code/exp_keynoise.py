"""Sensitivity of keyed supersession to key-assignment errors.

Missed merges (rate p) leave the predecessor active; false merges (rate q)
close another entity's active value. `lost_current` is the share of queries
whose current value is no longer held by any active fact.
"""

from __future__ import annotations

import arms as A
import common as C
import metrics as M


def run(cfg: dict, out) -> dict:
    r, ncfg = cfg["pfm"]["retrieval"], cfg["key_noise"]
    rows, realized = [], {}
    for seed in cfg["benchmark"]["seeds"]:
        bench = C.make_bench(cfg, seed, ncfg["corpus"])
        for p in ncfg["p_miss"]:
            for q in ncfg["q_false"]:
                store = C.build_store(cfg["pfm"], bench, noise=(p, q, seed))
                reach = C.reachable(store, bench.queries)
                realized[f"s{seed}/p{p}/q{q}"] = store.extractor_log
                for row in C.evaluate(A.PFMArm(store), bench, r["k"], r["budget"],
                                      seed=seed, p_miss=p, q_false=q):
                    rows.append(dict(row, lost_current=row["qid"] not in reach))
    M.write_jsonl(out / "keynoise.jsonl", rows)
    summary = {f"p{p}/q{q}": M.summarize(rs, metrics=M.METRICS + ("lost_current",), ci=False)["all"]
               for (p, q), rs in M.group(rows, "p_miss", "q_false").items()}
    C.write_json(out / "keynoise.json", {"summary": summary, "realized": realized})
    return summary
