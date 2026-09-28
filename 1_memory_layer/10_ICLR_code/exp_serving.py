"""Serving protocol under staleness and load.

lagged snapshots  For every query, the snapshot is computed on the store as it
                  was just before the last `lag` messages of the query's own
                  chain arrived (capped at the chain length), then judged
                  against current labels.
concurrent load   A construction thread ingests facts and prunes periodically
                  while the request thread issues snapshot reads and fresh
                  requests with a waiting budget. We time each call from the
                  request thread, with the collector enabled and disabled.
"""

from __future__ import annotations

import gc
import random
import sys
import threading
import time
from collections import defaultdict

import benchmark as B
import common as C
import exp_scaling as S
import metrics as M
import pfm


def lagged_rows(cfg: dict, seed: int, lags=(0, 1, 2)) -> list:
    bench = C.make_bench(cfg, seed, cfg["serving"]["corpus"])
    positions = defaultdict(list)                     # chain -> stream positions
    for i, (_, _, text) in enumerate(bench.messages):
        if text in bench.chain_of:
            positions[bench.chain_of[text]].append(i)
    queries = defaultdict(list)
    for q in bench.queries:
        queries[q.meta["chain"]].append(q)

    rows = []
    for lag in lags:
        due = defaultdict(list)                       # stream position -> chains to snapshot
        for chain, pos in positions.items():
            due[pos[-min(lag, len(pos))] if lag else len(bench.messages)].append(chain)
        store = C.build_store(cfg["pfm"], B.Bench([], [], bench.gazetteer, bench.label))
        for i in range(len(bench.messages) + 1):
            for chain in due.get(i, ()):
                for q in queries[chain]:
                    snap = store.retrieve(q.prefix, [q.partner], B.BASE)
                    rows.append(M.row(q, lag=lag, seed=seed, **M.outcome(snap.block, q)))
            if i < len(bench.messages):
                days_ago, partner, text = bench.messages[i]
                store.ingest(text, [partner], B.BASE - days_ago * B.DAY)
    return rows


def load_test(cfg: dict, gc_enabled: bool) -> dict:
    scfg = cfg["serving"]
    store, _, pool = S.build(cfg, scfg["store_facts"], cfg["benchmark"]["seeds"][0], timed=False)
    server = pfm.Server(store)
    server.publish("Reminder that Ent1 is due on ", [S.PARTNERS[0]], B.BASE)
    stop = threading.Event()
    stats = {"ingested": 0, "prunes": 0}

    def construction():
        rng = random.Random(1)
        messages = S.synthetic_messages(10 ** 9, pool, rng)
        next_prune = time.perf_counter() + scfg["prune_every_s"]
        while not stop.is_set():
            text, partner, now = next(messages)
            store.ingest(text, [partner], now)
            stats["ingested"] += 1
            if time.perf_counter() >= next_prune:
                store.prune(B.BASE)
                stats["prunes"] += 1
                next_prune += scfg["prune_every_s"]
            time.sleep(1 / scfg["ingest_facts_per_s"])

    def publisher():
        rng = random.Random(2)
        while not stop.wait(scfg["publish_every_s"]):
            server.publish(f"Reminder that Ent{rng.randrange(pool)} moved to ",
                           [rng.choice(S.PARTNERS)], B.BASE)

    threads = [threading.Thread(target=f, daemon=True) for f in (construction, publisher)]
    for t in threads:
        t.start()
    rng = random.Random(3)
    wait_s = scfg["fresh_wait_ms"] / 1e3
    read_ms, sched_ms, fresh_ms, fell_back, ages = [], [], [], 0, []
    parts = {k: [] for k in ("submit", "wait", "after", "overshoot")}
    sigma = []                      # scheduling the bound needs, per request
    gc.collect()
    if not gc_enabled:
        gc.disable()
    try:
        for _ in range(scfg["requests"]):
            due = time.perf_counter() + 0.002         # request becomes runnable at `due`
            time.sleep(0.002)
            t0 = time.perf_counter()
            snap = server.read()
            t1 = time.perf_counter()
            read_ms.append((t1 - t0) * 1e3)
            sched_ms.append((t0 - due) * 1e3)          # sigma: runnable -> running
            ages.append((t1 - snap.built_wall) * 1e3)
            ctx = f"Reminder that Ent{rng.randrange(pool)} is due on "
            trace = {}
            t0 = time.perf_counter()
            _, source = server.fresh(ctx, [rng.choice(S.PARTNERS)], B.BASE, wait_s, trace)
            fresh_ms.append((time.perf_counter() - t0) * 1e3)
            fell_back += source == "snapshot"
            for k, v in trace.items():
                parts[k].append(v)
            # Proposition 2 bounds waiting by omega + sigma + r for *some* sigma;
            # the experiment reports the sigma this runtime actually imposed.
            sigma.append(max(0.0, fresh_ms[-1] - scfg["fresh_wait_ms"] - trace["after"]))
    finally:
        gc.enable()
        stop.set()
        for t in threads:
            t.join(timeout=5)

    def pcts(v):
        return {f"p{p}": M.percentile(v, p) for p in (50, 99)} | {"max": max(v)}

    return {"gc_enabled": gc_enabled, "store_facts": scfg["store_facts"],
            "snapshot_read_ms": pcts(read_ms), "sleep_wakeup_ms": pcts(sched_ms),
            "fresh_ms": pcts(fresh_ms),
            "fresh_parts_ms": {k: pcts(v) for k, v in parts.items() if v},
            "sigma_required_ms": pcts(sigma),
            "fresh_fallback_rate": fell_back / scfg["requests"],
            "snapshot_age_ms": pcts(ages), **stats,
            "fresh_wait_budget_ms": scfg["fresh_wait_ms"],
            "switch_interval_s": sys.getswitchinterval()}


def run(cfg: dict, out) -> dict:
    rows = [r for seed in cfg["benchmark"]["seeds"] for r in lagged_rows(cfg, seed)]
    M.write_jsonl(out / "serving_lag.jsonl", rows)
    lag = {f"lag{l}": M.summarize(rs, ("all", "revised", "unrevised"), ci=False)
           for (l,), rs in M.group(rows, "lag").items()}
    load = [load_test(cfg, gc_enabled) for gc_enabled in (True, False)]
    result = {"lag": lag, "load": load, "wait_budget_ms": cfg["serving"]["fresh_wait_ms"]}
    C.write_json(out / "serving.json", result)
    return result
