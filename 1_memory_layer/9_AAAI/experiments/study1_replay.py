"""Study 1 — Offline replay from the deployed system (Python replication).

Replicates both Swift harnesses through the reference implementation
(../../5_dpfm/dpfm.py) plus the 20k-fact stress benchmark:

  1. Extraction quality: chitchat noise admitted (precision proxy),
     seed recall (known-limit sentence expected to miss).
  2. Fact availability A/B: memory ON vs OFF, per category.
  3. Prompt budget compliance.
  4. Retrieval latency at deployed scale (270 facts) and at 20k facts.

Paper reference numbers (Swift release build, Apple Silicon, 2026-07-16):
  small ON 6/7, large ON 24/25, OFF 0 everywhere;
  latency @270 p50=0.011ms p95=0.024ms; @20k p50=1.81ms p95=2.03ms.
The Python numbers replicate the *protocol*; absolute latency differs by
implementation language and is reported side by side.
"""

from __future__ import annotations

import random
import time
from typing import List

import common
import corpus as C
import dpfm


EXPECTED = {  # Swift harness results quoted in the paper (for the report diff)
    "small_on": "6/7", "large_on": "24/25", "off": "0",
    "seed_recall": "30/31", "noise_admitted": "0/16",
}


def _replay(mem, scenarios, latency_repeats: int) -> dict:
    hits_on = hits_off = 0
    expected_hits = expected_got = 0
    by_cat: dict = {}
    rows: List[dict] = []
    budget_ok = True
    budget = mem.prompt_char_budget + len("[Relevant memory]\n")

    for sc in scenarios:
        snap = mem.retrieve(sc.prefix, participants=[sc.partner],
                            k=mem.k_default, now=C.BASE)
        on_hit = C.prompt_contains(snap.prompt_block, sc.truth)
        off_hit = C.prompt_contains(sc.prefix, sc.truth)
        hits_on += on_hit
        hits_off += off_hit
        if sc.expect_hit:
            expected_hits += 1
            expected_got += on_hit
        c = by_cat.setdefault(sc.category, {"hit": 0, "n": 0})
        c["n"] += 1
        c["hit"] += on_hit
        if len(snap.prompt_block) > budget:
            budget_ok = False
        rows.append({"category": sc.category, "prefix": sc.prefix,
                     "truth": list(sc.truth), "on_hit": on_hit,
                     "off_hit": off_hit, "expect_hit": sc.expect_hit})

    lat: List[float] = []
    for _ in range(latency_repeats):
        for sc in scenarios:
            lat.append(mem.retrieve(sc.prefix, participants=[sc.partner],
                                    k=mem.k_default, now=C.BASE).latency_ms)

    return {
        "n_scenarios": len(scenarios),
        "hits_on": hits_on,
        "hits_off": hits_off,
        "expected_hits": expected_hits,
        "expected_got": expected_got,
        "by_category": by_cat,
        "prompt_budget_respected": budget_ok,
        "latency": common.latency_summary(lat),
        "scenarios": rows,
    }


def _stress_benchmark(dcfg: dict, n_facts: int, n_runs: int,
                      entity_pool: int, rng: random.Random) -> dict:
    """20k-fact latency benchmark: synthetic facts via add_fact (bypasses
    extraction — this measures the read path, which is what the paper claims)."""
    mem = common.ConfigurableDPFM(dcfg)
    verbs = ["is scheduled for", "is due on", "was sent to", "is assigned to",
             "moved to", "is confirmed for"]
    objs = ["the quarterly review", "the security audit", "the vendor call",
            "the migration", "the design doc", "the budget sync"]
    ents = [f"ent{gid}" for gid in range(entity_pool)]
    partners = [f"Partner {p}" for p in range(40)]

    t0 = time.perf_counter()
    for i in range(n_facts):
        e1, e2 = rng.choice(ents), rng.choice(ents)
        text = (f"{e1.capitalize()} {rng.choice(verbs)} {rng.choice(objs)} "
                f"on day {i % 28 + 1} with ref {e2.upper()}-{i}.")
        mem.add_fact(dpfm.FactDraft(text=text, entities=(e1, e2)),
                     source_id="stress",
                     participants=[rng.choice(partners)],
                     now=C.BASE - rng.uniform(0, 28) * C.DAY)
    build_s = time.perf_counter() - t0

    contexts = [f"Reminder that {rng.choice(ents)} {rng.choice(verbs)} "
                for _ in range(n_runs)]
    lat = [mem.retrieve(ctx, participants=[rng.choice(partners)],
                        k=dcfg["retrieval"]["k"], now=C.BASE).latency_ms
           for ctx in contexts]
    stats = mem.stats()
    return {"n_facts": stats["valid_facts"], "build_s": round(build_s, 2),
            "latency": common.latency_summary(lat)}


def run(cfg: dict, out_dir) -> dict:
    s1 = cfg["study1"]
    dcfg = cfg["dpfm"]
    rng = random.Random(cfg["seed"])

    # -- extraction quality (large corpus) ---------------------------------
    extractor = dpfm.make_rule_extractor(gazetteer=dcfg["extraction"]["gazetteer"])
    noise_admitted = sum(len(extractor(t)) for t in C.CHITCHAT)
    seed_recalled = sum(bool(extractor(t)) for _, _, t in C.SEEDS)

    # -- replays ------------------------------------------------------------
    small_mem = common.build_memory(dcfg, C.SMALL_CORPUS)
    small = _replay(small_mem, C.SMALL_SCENARIOS, s1["latency_repeats"])

    large_mem = common.build_memory(dcfg, C.large_corpus())
    large = _replay(large_mem, C.LARGE_SCENARIOS, s1["latency_repeats"])
    large_stats = large_mem.stats()

    # -- stress benchmark ----------------------------------------------------
    stress = _stress_benchmark(dcfg, s1["stress"]["n_facts"],
                               s1["stress"]["n_runs"],
                               s1["stress"]["entity_pool"], rng)

    result = {
        "status": "DONE",
        "extraction": {
            "noise_admitted": f"{noise_admitted}/{len(C.CHITCHAT)}",
            "seed_recall": f"{seed_recalled}/{len(C.SEEDS)}",
            "known_limit_seeds": C.KNOWN_LIMIT_SEEDS,
            "large_index": large_stats,
        },
        "small": small,
        "large": large,
        "stress_20k": stress,
        "expected_from_paper": EXPECTED,
    }
    common.write_json(out_dir / "study1.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 1: {r.get('status')}"
    s, l, k = r["small"], r["large"], r["stress_20k"]
    cats = ", ".join(f"{c} {v['hit']}/{v['n']}"
                     for c, v in sorted(l["by_category"].items()))
    return (
        f"Study 1: availability small ON {s['hits_on']}/{s['n_scenarios']} "
        f"OFF {s['hits_off']}/{s['n_scenarios']}; "
        f"large ON {l['hits_on']}/{l['n_scenarios']} "
        f"OFF {l['hits_off']}/{l['n_scenarios']} ({cats}); "
        f"extraction noise {r['extraction']['noise_admitted']}, "
        f"seeds {r['extraction']['seed_recall']}; "
        f"latency @270 p50={l['latency']['p50_ms']}ms "
        f"p95={l['latency']['p95_ms']}ms; "
        f"@{k['n_facts']} p50={k['latency']['p50_ms']}ms "
        f"p95={k['latency']['p95_ms']}ms; "
        f"budget_ok={l['prompt_budget_respected']}"
    )
