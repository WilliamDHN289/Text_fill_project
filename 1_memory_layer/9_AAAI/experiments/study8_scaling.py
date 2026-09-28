"""Study 8 — Systems scaling (paper task 6).

For each store size in the grid: build a fresh PFM store from synthetic
facts, then measure

  update cost      per-fact add latency p50/p95 during the build, plus
                   steady-state adds and one prune pass at full size
  retrieval        p50/p95/p99 over `n_queries` mixed queries
  footprint        process RSS delta (psutil) around the build, plus index
                   statistics (facts, terms, posting entries)

Environment (hardware, OS, thread situation, timing boundary, cache
assumptions) is recorded in full so the numbers are reproducible.
"""

from __future__ import annotations

import gc
import random
import statistics
import subprocess
import time
from typing import List

import common
import dpfm


def _env(cfg) -> dict:
    def sysctl(k):
        try:
            return subprocess.check_output(["sysctl", "-n", k], text=True).strip()
        except Exception:
            return None
    base = common.env_info()
    base.update({
        "cpu": sysctl("machdep.cpu.brand_string"),
        "cores": sysctl("hw.ncpu"),
        "ram_bytes": sysctl("hw.memsize"),
        "threading": ("hot path single-threaded; DPFM consolidator/prefetch "
                      "daemon threads exist but are idle (sync ingest via "
                      "add_fact)"),
        "timing_boundary": ("per-add: perf_counter around add_fact() "
                            "(extraction bypassed; dedup+supersede+index+"
                            "graph update included). retrieval: perf_counter "
                            "around retrieve() incl. query build, scoring, "
                            "ranking, block formatting"),
        "cache_assumptions": ("warm process, data fully in RAM (no disk on "
                              "the measured path); CPython 3.11, no JIT; "
                              "first 50 queries discarded as warmup"),
    })
    return base


def _synthetic_drafts(n: int, pool: int, rng: random.Random):
    verbs = ["is scheduled for", "is due on", "was sent to", "is assigned to",
             "moved to", "is confirmed for"]
    objs = ["the quarterly review", "the security audit", "the vendor call",
            "the migration", "the design doc", "the budget sync"]
    ents = [f"ent{g}" for g in range(pool)]
    for i in range(n):
        e1, e2 = rng.choice(ents), rng.choice(ents)
        text = (f"{e1.capitalize()} {rng.choice(verbs)} {rng.choice(objs)} "
                f"on day {i % 28 + 1} with ref {e2.upper()}-{i}.")
        yield dpfm.FactDraft(text=text, entities=(e1, e2)), e1


def _pcts(vals: List[float]) -> dict:
    v = sorted(vals)
    return {"p50_ms": round(common.percentile(v, 50), 4),
            "p95_ms": round(common.percentile(v, 95), 4),
            "p99_ms": round(common.percentile(v, 99), 4)}


def run(cfg: dict, out_dir) -> dict:
    import psutil
    s8 = cfg["study8"]
    proc = psutil.Process()
    rows = []
    for n in s8["grid"]:
        rng = random.Random(cfg["seed"] + n)
        pool = max(200, n // s8["entity_pool_div"])
        gc.collect()
        rss0 = proc.memory_info().rss
        mem = common.ConfigurableDPFM(cfg["dpfm"])
        partners = [f"Partner {p}" for p in range(40)]

        add_lat: List[float] = []
        t_build0 = time.perf_counter()
        for draft, e1 in _synthetic_drafts(n, pool, rng):
            t0 = time.perf_counter()
            mem.add_fact(draft, source_id="scale",
                         participants=[rng.choice(partners)],
                         now=common.BASE - rng.uniform(0, 28) * common.DAY)
            add_lat.append((time.perf_counter() - t0) * 1000.0)
        build_s = time.perf_counter() - t_build0
        gc.collect()
        rss1 = proc.memory_info().rss

        # steady-state updates at full size
        upd_lat: List[float] = []
        for draft, _ in _synthetic_drafts(200, pool, random.Random(1)):
            t0 = time.perf_counter()
            mem.add_fact(draft, source_id="scale-upd",
                         participants=[partners[0]], now=common.BASE)
            upd_lat.append((time.perf_counter() - t0) * 1000.0)

        # retrieval
        ents = [f"ent{g}" for g in range(pool)]
        verbs = ["is scheduled for", "moved to", "is due on"]
        q_lat: List[float] = []
        nq = s8["n_queries"] + 50
        for i in range(nq):
            ctx = f"Reminder that {rng.choice(ents)} {rng.choice(verbs)} "
            t0 = time.perf_counter()
            mem.retrieve(ctx, participants=[rng.choice(partners)],
                         k=cfg["dpfm"]["retrieval"]["k"], now=common.BASE)
            if i >= 50:                                   # warmup discarded
                q_lat.append((time.perf_counter() - t0) * 1000.0)

        t0 = time.perf_counter()
        mem._prune(0.02)
        prune_ms = (time.perf_counter() - t0) * 1000.0

        stats = mem.stats()
        posting_entries = sum(len(p) for p in mem.index.postings.values())
        rows.append({
            "n_facts_requested": n,
            "valid_facts": stats["valid_facts"],
            "build_s": round(build_s, 2),
            "ingest_facts_per_s": round(n / build_s, 0),
            "add_latency": _pcts(add_lat),
            "update_latency_at_size": _pcts(upd_lat),
            "retrieval_latency": _pcts(q_lat),
            "prune_ms": round(prune_ms, 1),
            "rss_delta_mb": round((rss1 - rss0) / 1e6, 1),
            "index": {"terms": stats["index_terms"],
                      "posting_entries": posting_entries,
                      "entities": stats["entities"],
                      "graph_nodes": stats["graph_nodes"]},
        })
        del mem
        gc.collect()

    result = {"status": "DONE", "env": _env(cfg), "grid": rows}
    common.write_json(out_dir / "study8.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 8: {r.get('status')}"
    lines = [f"Study 8 (scaling on {r['env'].get('cpu')}):"]
    for row in r["grid"]:
        rl = row["retrieval_latency"]
        lines.append(
            f"  {row['n_facts_requested']:>7,} facts: retrieve "
            f"p50={rl['p50_ms']}ms p95={rl['p95_ms']}ms p99={rl['p99_ms']}ms; "
            f"add p50={row['add_latency']['p50_ms']}ms; "
            f"RSS +{row['rss_delta_mb']}MB; "
            f"ingest {row['ingest_facts_per_s']:.0f}/s")
    return "\n".join(lines)
