"""Where lexical retrieval stops being cheaper than dense retrieval.

For each store size we time PFM's fresh path and a dense retriever (MiniLM
query encoding plus an exact scan of the fact matrix) on the same synthetic
store, under two term distributions that differ in how many verbs and objects the
facts share, which sets the length of the longest posting list a query
traverses.
"""

from __future__ import annotations

import gc
import random
import time

import arms as A
import benchmark as B
import common as C
import exp_scaling as S
import metrics as M
import pfm


def _queries(pool: int, n: int, seed: int, vocab: int):
    rng = random.Random(seed)
    verbs = S.VERBS[:vocab]
    return [(f"Reminder that Ent{rng.randrange(pool)} {rng.choice(verbs)} ",
             [rng.choice(S.PARTNERS)]) for _ in range(n)]


def term_stats(store, queries) -> dict:
    """Longest posting list a query has to traverse."""
    longest = []
    for prefix, partners in queries:
        lengths = [len(store.index.postings.get(t, ())) for t in store.build_query(prefix, partners)]
        longest.append(max(lengths) if lengths else 0)
    return {f"longest_posting_p{p}": M.percentile(longest, p) for p in (50, 95)}


def run(cfg: dict, out) -> dict:
    ccfg, r = cfg["crossover"], cfg["pfm"]["retrieval"]
    encoder = A.Encoder(cfg["dense"])
    rows = []
    for name, spec in ccfg["distributions"].items():
        for n in ccfg["grid"]:
            seed = cfg["benchmark"]["seeds"][0] + n
            pool = max(200, n // spec["pool_div"])
            store, _, _ = S.build(cfg, n, seed, timed=False, pool=pool, vocab=spec["vocab"])
            dense = A.DenseArm(store, encoder, shortlist=r["shortlist"])
            queries = _queries(pool, ccfg["queries"] + ccfg["warmup"], seed, spec["vocab"])
            stats = term_stats(store, queries)
            gc.collect()
            gc.freeze()
            lat = {"pfm": [], "dense": [], "dense_encode": []}
            for prefix, partners in queries:
                t0 = time.perf_counter()
                store.retrieve(prefix, partners, B.BASE)
                t1 = time.perf_counter()
                dense.rank(prefix, partners, B.BASE)
                t2 = time.perf_counter()
                lat["pfm"].append((t1 - t0) * 1e3)
                lat["dense"].append((t2 - t1) * 1e3)
                lat["dense_encode"].append(dense.last_encode_ms)
            gc.unfreeze()
            rows.append({"distribution": name, "entity_pool": pool, "facts": n,
                         "vocab": spec["vocab"], **stats,
                         "posting_entries": sum(len(p) for p in store.index.postings.values()),
                         **{f"{k}_p50": M.percentile(v[ccfg["warmup"]:], 50)
                            for k, v in lat.items()},
                         **{f"{k}_p95": M.percentile(v[ccfg["warmup"]:], 95)
                            for k, v in lat.items()}})
            print(f"  {name} n={n}: pfm {rows[-1]['pfm_p50']:.2f} ms, "
                  f"dense {rows[-1]['dense_p50']:.2f} ms", flush=True)
            del store, dense
            gc.collect()
    result = {"rows": rows, "encoder": encoder.info,
              "note": "one request at a time; dense = query encoding + exact scan of the "
                      "fact matrix, no ANN index"}
    C.write_json(out / "crossover.json", result)
    return result
