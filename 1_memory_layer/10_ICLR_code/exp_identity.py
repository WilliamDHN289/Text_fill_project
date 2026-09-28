"""Identity resolution and abstention, the two decisions supersession leaves open.

The ablation of Section 6 shows that a hard participant filter removes every
wrong-person exposure on the main benchmark, and the participants slice shows
why that is not a method: it works because the benchmark makes the
interlocutor the subject of the fact, and it recalls almost nothing about
third parties. This experiment measures the alternative of resolving the
mention instead of filtering on the conversation, and measures abstention
separately on answerable and unanswerable queries, which a single clean rate
cannot do.

Reported on three corpora: the main benchmark, the participants slice (the
subject is not the interlocutor), and the hard-identity slice (same first
name, same slot, same noun, plus queries with no answer).
"""

from __future__ import annotations

import arms as A
import common as C
import identity as I
import metrics as M
import slices as S

CASES = S.CASES


def _arms(store, cfg):
    base = A.PFMArm(store)
    icfg = cfg["identity"]
    out = [base, A.ParticipantFilter(base), A.RelativeCutoff(base, cfg["slices"]["cutoff"]),
           I.IdentityArm(base, store, hard=True),
           I.ContextAffinity(base, store),
           I.SlotAbstain(I.IdentityArm(base, store, hard=True), store)]
    out += [I.SlotAbstain(I.IdentityArm(base, store, hard=True), store, tau=t)
            for t in icfg["posterior_tau"] if t != 0.5]
    out += [I.MarginAbstain(base, t) for t in icfg["abstain_tau"]]
    return out


def run(cfg: dict, out) -> dict:
    r = cfg["pfm"]["retrieval"]
    M.SLICES.update({c: (lambda m, c=c: m.get("case") == c) for c in CASES})
    rows = []
    for seed in cfg["benchmark"]["seeds"]:
        main = C.make_bench(cfg, seed, cfg["identity"]["corpus"])
        for name, bench in (("main", main), ("participants", S.participants(main, seed)),
                            ("hard", S.hard_identity(cfg["slices"]["hard_pairs"], seed))):
            store = C.build_store(cfg["pfm"], bench)
            for arm in _arms(store, cfg):
                rows += [dict(row, corpus=name)
                         for row in C.evaluate(arm, bench, r["k"], r["budget"], seed=seed)]
    M.write_jsonl(out / "identity.jsonl", rows)

    want = {"main": ("all", "ambiguous"), "participants": ("all",) + CASES,
            "hard": ("answerable", "unanswerable")}
    summary = {f"{corpus}/{arm}": M.summarize(rs, want[corpus], ci=False)
               for (corpus, arm), rs in M.group(rows, "corpus", "arm").items()}
    ref = {r["qid"]: r for r in rows if r["corpus"] == "main" and r["arm"] == "pfm"}
    tests = {}
    for (corpus, arm), rs in M.group(rows, "corpus", "arm").items():
        if corpus == "main" and arm != "pfm":
            tests[arm] = M.paired_difference(rs, [ref[x["qid"]] for x in rs])
    result = {"summary": summary, "vs_pfm_main": tests}
    C.write_json(out / "identity.json", result)
    return result
