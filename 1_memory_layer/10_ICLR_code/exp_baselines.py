"""Retrieval baselines under identical corpus, budget, and machine.

Quality: every arm on every benchmark seed (per-query rows).
Latency: primary seed only; each (query, repeat) times all arms in a freshly
shuffled order, and every run is kept. Snapshot variants are timed as the
read of a published result.
"""

from __future__ import annotations

import random
import time

import arms as A
import benchmark as B
import common as C
import metrics as M
import pfm


def make_arms(store: pfm.PFM, encoder: A.Encoder) -> list:
    out = [A.PFMArm(store)]
    for p in (False, True):
        bm25, bm25_v = A.BM25Arm(store, participants=p), A.BM25Arm(store, True, participants=p)
        dense = A.DenseArm(store, encoder, participants=p)
        dense_v = A.DenseArm(store, encoder, valid_only=True, participants=p)
        out += [bm25, A.BM25Arm(store, recency=True, participants=p), bm25_v,
                dense, dense_v, A.HybridArm(bm25, dense), A.HybridArm(bm25_v, dense_v)]
    return out


def time_snapshot_read(store: pfm.PFM, q: B.Query) -> float:
    server = pfm.Server(store)
    server.publish(q.prefix, [q.partner], B.BASE)
    t0 = time.perf_counter()
    server.read()
    return (time.perf_counter() - t0) * 1e3


def run(cfg: dict, out) -> dict:
    r, bcfg = cfg["pfm"]["retrieval"], cfg["baselines"]
    encoder = A.Encoder(cfg["dense"])
    rows, lat_rows, build = [], [], {}
    primary = cfg["benchmark"]["seeds"][0]
    for seed in cfg["benchmark"]["seeds"]:
        bench = C.make_bench(cfg, seed, bcfg["corpus"])
        store = C.build_store(cfg["pfm"], bench)
        arms = make_arms(store, encoder)
        build[seed] = {a.name: round(getattr(a, "build_s", 0.0), 3) for a in arms}
        for arm in arms:
            rows += C.evaluate(arm, bench, r["k"], r["budget"], seed=seed)
        if seed != primary:
            continue
        rng = random.Random(seed)
        for rep in range(bcfg["latency_repeats"]):
            for q in bench.queries:
                for arm in rng.sample(arms, len(arms)):
                    _, _, ms = A.serve(arm, q.prefix, [q.partner], B.BASE, r["k"], r["budget"])
                    lat_rows.append({"qid": q.qid, "arm": arm.name, "rep": rep, "ms": ms,
                                     "encode_ms": getattr(arm, "last_encode_ms", None)})
                lat_rows.append({"qid": q.qid, "arm": "snapshot_read", "rep": rep,
                                 "ms": time_snapshot_read(store, q), "encode_ms": None})
    M.write_jsonl(out / "baselines.jsonl", rows)
    M.write_jsonl(out / "baselines_latency.jsonl", lat_rows)
    info = {"encoder": encoder.info, "dense_build_s": build, "primary_seed": primary,
            "timing_boundary": "perf_counter around rank + select + format_block, batch 1, "
                               "one request at a time; arm order reshuffled per query"}
    C.write_json(out / "baselines.json", info)
    return info
