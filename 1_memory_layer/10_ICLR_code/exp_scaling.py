"""Store-size scaling on a dense synthetic term distribution.

Latency and memory are measured in separate builds: tracemalloc slows
allocation, so it never runs while anything is timed. Queries are timed twice,
with the default collector and after gc.freeze(), to separate collector
pauses from retrieval cost.
"""

from __future__ import annotations

import gc
import random
import re
import time
import tracemalloc

import benchmark as B
import metrics as M
import common as C
import pfm

_ENT = re.compile(r"\bent\d+\b", re.I)
VERBS = ["is scheduled for", "is due on", "was sent to", "is assigned to", "moved to",
         "is confirmed for"]
OBJECTS = ["the quarterly review", "the security audit", "the vendor call", "the migration",
           "the design doc", "the budget sync"]
PARTNERS = [f"Colleague{i}" for i in range(40)]   # one token each: no term shared by every fact


def synthetic_extractor(text: str):
    return [pfm.Draft(text, tuple(sorted({e.lower() for e in _ENT.findall(text)})))]


def synthetic_messages(n: int, pool: int, rng: random.Random, vocab: int = None):
    """Each fact names two entities from a pool of `pool` and one of `vocab`
    verb/object pairs, so both the entity terms and the shared terms have
    controlled posting lists."""
    verbs, objects = VERBS[:vocab or len(VERBS)], OBJECTS[:vocab or len(OBJECTS)]
    for i in range(n):
        e1, e2 = rng.randrange(pool), rng.randrange(pool)
        yield (f"Ent{e1} {rng.choice(verbs)} {rng.choice(objects)} on day {i % 28 + 1} "
               f"with ref ENT{e2}-{i}.", rng.choice(PARTNERS),
               B.BASE - rng.uniform(0, 28) * B.DAY)


def build(cfg: dict, n: int, seed: int, timed: bool, pool: int = None, vocab: int = None):
    rng = random.Random(seed)
    store = pfm.PFM(cfg["pfm"], synthetic_extractor)
    add_ms = []
    pool = pool or max(200, n // cfg["scaling"]["entity_pool_div"])
    for text, partner, now in synthetic_messages(n, pool, rng, vocab):
        t0 = time.perf_counter()
        store.ingest(text, [partner], now)
        if timed:
            add_ms.append((time.perf_counter() - t0) * 1e3)
    return store, add_ms, pool


def time_queries(cfg: dict, store: pfm.PFM, pool: int, seed: int) -> list:
    scfg, rng, lat = cfg["scaling"], random.Random(seed + 1), []
    for i in range(scfg["warmup"] + scfg["queries"]):
        ctx = f"Reminder that Ent{rng.randrange(pool)} {rng.choice(VERBS[:3])} "
        t0 = time.perf_counter()
        store.retrieve(ctx, [rng.choice(PARTNERS)], B.BASE)
        if i >= scfg["warmup"]:
            lat.append((time.perf_counter() - t0) * 1e3)
    return lat


def run(cfg: dict, out) -> dict:
    scfg, r = cfg["scaling"], cfg["pfm"]["retrieval"]
    rows = []
    for n in scfg["grid"]:
        seed = cfg["benchmark"]["seeds"][0] + n
        gc.collect()
        t0 = time.perf_counter()
        store, add_ms, pool = build(cfg, n, seed, timed=True)
        build_s = time.perf_counter() - t0
        gc.collect()
        lat = time_queries(cfg, store, pool, seed)
        gc.freeze()                              # long-lived store leaves the collector's scans
        lat_frozen = time_queries(cfg, store, pool, seed)
        gc.unfreeze()
        t0 = time.perf_counter()
        store.prune(B.BASE)
        prune_ms = (time.perf_counter() - t0) * 1e3
        postings = sum(len(p) for p in store.index.postings.values())
        del store
        gc.collect()
        tracemalloc.start()
        store, _, _ = build(cfg, n, seed, timed=False)
        traced_mb = tracemalloc.get_traced_memory()[0] / 1e6
        tracemalloc.stop()
        del store
        rows.append({"facts": n, "entity_pool": pool, "queries": len(lat),
                     **{f"p{p}_ms": M.percentile(lat, p) for p in (50, 95, 99)},
                     "max_ms": max(lat),
                     **{f"frozen_p{p}_ms": M.percentile(lat_frozen, p) for p in (50, 95, 99)},
                     "add_p50_ms": M.percentile(add_ms, 50),
                     "add_p99_ms": M.percentile(add_ms, 99),
                     "ingest_per_s": n / build_s, "prune_ms": prune_ms,
                     "posting_entries": postings, "traced_mb": traced_mb})
        print(f"  scaling n={n}: p50={rows[-1]['p50_ms']:.2f}ms p99={rows[-1]['p99_ms']:.2f}ms",
              flush=True)
    C.write_json(out / "scaling.json", {"env": C.env_info(), "rows": rows,
                                        "timing_boundary": "perf_counter around retrieve(): "
                                        "query build, scoring, ranking, selection, formatting"})
    return rows
