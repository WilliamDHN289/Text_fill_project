"""Slices that probe assumptions the main benchmark builds in.

multi_valued   key granularity when one person has two instances of a slot
reorder        transaction-time versus event-time supersession
participants   the participant is not the subject, is a group, or is missing
hard_identity  same first name, noun, template, and age; plus queries with no
               answer, where the only correct block is one that exposes nothing
"""

from __future__ import annotations

import arms as A
import common as C
import metrics as M
import slices as S


def _rows(arm, bench, cfg, **tags):
    r = cfg["pfm"]["retrieval"]
    return C.evaluate(arm, bench, r["k"], r["budget"], **tags)


def run(cfg: dict, out) -> dict:
    scfg, rows, info = cfg["slices"], [], {}
    for seed in cfg["benchmark"]["seeds"]:
        # (a) two instances of one slot type per person
        bench = S.multi_valued(scfg["multi_valued_people"], seed)
        for name, kwargs in (("key(entity,slot)", {"granularity": "slot"}),
                             ("key(entity,slot,noun)", {"granularity": "noun"}),
                             ("keyless", {"keyed": False})):
            store = C.build_store(cfg["pfm"], bench, **kwargs)
            reach = C.reachable(store, bench.queries)
            rows += [dict(r, slice_name="multi_valued", store=name,
                          lost_current=r["qid"] not in reach)
                     for r in _rows(A.PFMArm(store, name), bench, cfg, seed=seed)]

        # (b) out-of-order arrival
        base = C.make_bench(cfg, seed, scfg["corpus"])
        shuffled = S.reorder(base, scfg["reorder_fraction"], seed)
        info[f"reordered_chains_s{seed}"] = shuffled.reordered_chains
        for name, bench, order in (("in order", base, "transaction"),
                                   ("out of order", shuffled, "transaction"),
                                   ("out of order, event time", shuffled, "event")):
            store = C.build_store(C.merged(cfg["pfm"], {"admission": {"order_by": order}}), bench)
            rows += [dict(r, slice_name="reorder", store=name, case="all")
                     for r in _rows(A.PFMArm(store, name), bench, cfg, seed=seed)]

        # (c) participant is not the subject
        bench = S.participants(base, seed)
        store = C.build_store(cfg["pfm"], bench)
        for arm in (A.PFMArm(store), A.ParticipantFilter(A.PFMArm(store))):
            rows += [dict(r, slice_name="participants", store=arm.name)
                     for r in _rows(arm, bench, cfg, seed=seed)]

        # (d) hard distractors and queries with no answer
        bench = S.hard_identity(scfg["hard_pairs"], seed)
        store = C.build_store(cfg["pfm"], bench)
        full = A.PFMArm(store)
        for arm in (full, A.RelativeCutoff(full, scfg["cutoff"]), A.ParticipantFilter(full)):
            rows += [dict(r, slice_name="hard_identity", store=arm.name)
                     for r in _rows(arm, bench, cfg, seed=seed)]

    M.write_jsonl(out / "slices.jsonl", rows)
    summary = {f"{s}/{st}/{c}": M.summarize(rs, ci=False)["all"]
               for (s, st, c), rs in M.group(rows, "slice_name", "store", "case").items()}
    C.write_json(out / "slices.json", {"summary": summary, "info": info})
    return summary
