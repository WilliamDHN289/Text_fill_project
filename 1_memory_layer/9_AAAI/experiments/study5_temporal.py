"""Study 5 — Temporal correctness end to end (paper tasks 1 + 5).

Two arms on the controlled update benchmark, identical extraction coverage:

  keyed    TemporalDPFM + key-emitting extractor: same-key facts supersede
           bitemporally (supersession checked BEFORE Jaccard dedup, so
           verbatim revisions update instead of being swallowed).
  keyless  the deployed configuration: same sentences, keys stripped;
           recency ordering is the only defense against staleness.

Reported per (corpus size x prompt budget x arm), with 95% Wilson CIs:
  current-fact recall, stale exposure, co-injection (current AND stale in
  the same prompt), wrong-person exposure, clean-correct; plus slices by
  revision depth, cancellation, verbatim revisions, ambiguity, paraphrase
  level, fact age, and distractor load.
"""

from __future__ import annotations

from typing import Dict, List

import benchmark as B
import common
import keyed_extractor as KE


def eval_query(block: str, q: B.Query) -> Dict[str, bool]:
    cur = B.contains(block, q.current)
    stale = any(B.contains(block, v) for v in q.stale)
    wrong = any(B.contains(block, v) for v in q.wrong)
    return {"current": cur, "stale": stale, "wrong": wrong,
            "coinject": cur and stale,
            "clean": cur and not stale and not wrong}


def _rate(rows: List[dict], key: str) -> dict:
    k = sum(r[key] for r in rows)
    p, lo, hi = B.wilson(k, len(rows))
    return {"rate": round(p, 4), "lo": round(lo, 4), "hi": round(hi, 4),
            "k": k, "n": len(rows)}


def _slices(rows: List[dict]) -> dict:
    def by(pred, name):
        sub = [r for r in rows if pred(r["meta"])]
        return {name: {m: _rate(sub, m)["rate"] for m in
                       ("current", "stale", "coinject", "clean")},
                f"{name}_n": len(sub)} if sub else {}

    out = {}
    for d in range(5):
        out.update(by(lambda m, d=d: m["revisions"] == d, f"rev{d}"))
    out.update(by(lambda m: m["cancel"], "cancelled"))
    out.update(by(lambda m: m["verbatim"], "verbatim_rev"))
    out.update(by(lambda m: m["ambiguous"], "ambiguous"))
    out.update(by(lambda m: m["q_level"] == 1, "paraphrased_query"))
    out.update(by(lambda m: m["age_days"] <= 2, "age<=2d"))
    out.update(by(lambda m: m["age_days"] > 10, "age>10d"))
    return out


def run_arms(cfg: dict, bench: B.Bench, budgets, arms) -> dict:
    dcfg = cfg["dpfm"]
    gaz_cfg = dict(dcfg, extraction={"gazetteer": bench.gazetteer})
    keyed_ex = KE.make_keyed_extractor(bench.gazetteer)
    mems = {}
    if "keyed" in arms:
        mems["keyed"] = common.build_memory(gaz_cfg, bench.messages,
                                            extractor=keyed_ex,
                                            cls=common.TemporalDPFM)
    if "keyless" in arms:
        mems["keyless"] = common.build_memory(gaz_cfg, bench.messages,
                                              extractor=KE.strip_keys(keyed_ex))
    out = {}
    for arm, mem in mems.items():
        stats = mem.stats()
        # diagnosis metric: is the labeled current value present in ANY valid
        # fact? separates extraction/supersession failures from ranking ones
        valid_texts = [f.text for f in mem.facts.values() if f.valid]
        reachable = sum(
            any(B.contains(t, q.current) for t in valid_texts)
            for q in bench.queries)
        stats = dict(stats, label_reachable=round(
            reachable / len(bench.queries), 4))
        for budget in budgets:
            mem.prompt_char_budget = budget
            rows = []
            for q in bench.queries:
                snap = mem.retrieve(q.prefix, participants=[q.partner],
                                    k=dcfg["retrieval"]["k"], now=common.BASE)
                r = eval_query(snap.prompt_block, q)
                r["meta"] = q.meta
                rows.append(r)
            out[f"{arm}/b{budget}"] = {
                "metrics": {m: _rate(rows, m) for m in
                            ("current", "stale", "coinject", "wrong", "clean")},
                "slices": _slices(rows),
                "store": stats,
            }
    return out


def run(cfg: dict, out_dir) -> dict:
    s5 = cfg["study5"]
    results = {}
    n_queries = None
    for label, n_fill in s5["corpora"].items():
        bench = B.generate(s5["n_chains"], s5["seed"], n_fill,
                           s5["p_cancel"],
                           {int(k): v for k, v in s5["rev_weights"].items()},
                           label)
        n_queries = len(bench.queries)
        results[label] = run_arms(cfg, bench, s5["budgets"], s5["arms"])
    result = {"status": "DONE", "n_chains": s5["n_chains"],
              "n_queries_per_corpus": n_queries, "cells": results}
    common.write_json(out_dir / "study5.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 5: {r.get('status')}"
    lines = [f"Study 5 (temporal): {r['n_queries_per_corpus']} labeled "
             f"queries/corpus, {r['n_chains']} chains"]
    for corpus, cells in r["cells"].items():
        for cell, data in sorted(cells.items()):
            m = data["metrics"]
            lines.append(
                f"  {corpus:6s} {cell:14s} current {m['current']['rate']:.3f} "
                f"stale {m['stale']['rate']:.3f} coinject "
                f"{m['coinject']['rate']:.3f} wrong {m['wrong']['rate']:.3f} "
                f"clean {m['clean']['rate']:.3f}")
    return "\n".join(lines)
