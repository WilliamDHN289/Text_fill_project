"""Query-time model calls as an alternative to the write-time and
serving-time rules.

Each of the three failures can also be attacked by asking a model at request
time, which is what a system that keeps every version and resolves conflicts
on read does. This experiment puts those three baselines on the same corpus,
arms and metrics as the rules they would replace, and prices the model call
against the deadlines of Section 6.

  temporal rerank   candidate lines from a validity-agnostic retriever, dated;
                    the model says which state the value in force. Replaces
                    keyed supersession.
  entity resolve    the request and the people whose name it could denote; the
                    model picks one. Replaces the posterior of Section 7.
  abstain judge     the block and the request; the model says whether the block
                    answers it. Replaces the slot gate.

Calls are cached by prompt, so a re-run costs nothing.
"""

from __future__ import annotations

import re
import time
from typing import Dict, List, Sequence

import arms as A
import benchmark as B
import common as C
import exp_extractor as E
import identity as I
import metrics as M
import pfm

RERANK = ("Memory lines, each with the date it was recorded:\n{lines}\n\n"
          "Request: {prefix}\n\nSome lines may state a value that was later revised. "
          "Reply with the numbers of the lines that state the value in force now, "
          "comma separated, most relevant first. Numbers only.")

RESOLVE = ("Unfinished message to {partner}:\n{prefix}\n\n"
           "The name in that message could refer to any of these people:\n{people}\n\n"
           "Reply with the number of the person the message is about. Number only.")

ABSTAIN = ("Memory:\n{block}\n\nRequest: {prefix}\n\n"
           "Does the memory state the value this request asks for, about the person or "
           "project it asks about? Reply YES or NO.")

LINES, RESOLVE_TOKENS = 8, 8


def _ids(reply: str, n: int) -> List[int]:
    return [int(x) - 1 for x in re.findall(r"\d+", reply) if 1 <= int(x) <= n]


class Timed(A.Arm):
    """Records the wall time its model calls take, so the request-path cost of
    each baseline can be reported next to the lexical path's."""

    def __init__(self, name: str):
        self.name, self.call_ms = name, []

    def ask(self, fn, *args):
        t0 = time.perf_counter()
        out = fn(*args)
        self.call_ms.append((time.perf_counter() - t0) * 1e3)
        return out


class TemporalRerank(Timed):
    def __init__(self, inner: A.Arm, ask, n: int = LINES):
        super().__init__(f"{inner.name}|llm_temporal_rerank")
        self.inner, self.asker, self.n = inner, ask, n

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)[:self.n]
        if len(ranked) < 2:
            return ranked
        lines = "\n".join(f"{i + 1}. {pfm.fact_line(f)[2:]}" for i, (f, _) in enumerate(ranked))
        reply = self.ask(self.asker, RERANK.format(lines=lines, prefix=prefix), 24)
        keep = _ids(reply, len(ranked))
        return [ranked[i] for i in keep] if keep else ranked


class EntityResolve(Timed):
    def __init__(self, inner: A.Arm, store: pfm.PFM, ask):
        super().__init__(f"{inner.name}|llm_entity_resolve")
        self.inner, self.store, self.asker = inner, store, ask

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        cands = I.candidates(self.store, prefix)
        if len(cands) < 2:
            return ranked
        people = "\n".join(f"{i + 1}. {c.title()}" for i, c in enumerate(cands))
        reply = self.ask(self.asker, RESOLVE.format(partner=", ".join(partners), prefix=prefix,
                                                    people=people), RESOLVE_TOKENS)
        picked = _ids(reply, len(cands))
        if not picked:
            return ranked
        want = cands[picked[0]]
        return [(f, s) for f, s in ranked
                if want in f.entities or not (set(f.entities) & set(cands))]


class AbstainJudge(Timed):
    def __init__(self, inner: A.Arm, ask, k: int, budget: int):
        super().__init__(f"{inner.name}|llm_abstain")
        self.inner, self.asker, self.k, self.budget = inner, ask, k, budget

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        block = pfm.format_block(pfm.select([f for f, _ in ranked], self.k, self.budget))
        if not block:
            return ranked
        reply = self.ask(self.asker, ABSTAIN.format(block=block, prefix=prefix), RESOLVE_TOKENS)
        return [] if reply.strip().upper().startswith("NO") else ranked


def run(cfg: dict, out) -> dict:
    r, scfg = cfg["pfm"]["retrieval"], cfg["systems"]
    ask = E.Cache(out / "systems_cache.json", scfg["model"], 24)
    seeds = cfg["benchmark"]["seeds"][:scfg["seeds"]]
    rows, cost = [], {}
    for seed in seeds:
        import slices as S
        main = C.make_bench(cfg, seed, scfg["corpus"])
        hard = S.hard_identity(cfg["slices"]["hard_pairs"], seed)
        for corpus, bench in (("main", main), ("hard", hard)):
            store = C.build_store(cfg["pfm"], bench)
            base, stale_prone = A.PFMArm(store), A.BM25Arm(store, participants=True)
            candidates = [
                base, stale_prone,
                TemporalRerank(stale_prone, ask),
                A.ParticipantFilter(base),
                I.IdentityArm(base, store, hard=True),
                EntityResolve(base, store, ask),
                I.SlotAbstain(I.IdentityArm(base, store, hard=True), store),
                AbstainJudge(base, ask, r["k"], r["budget"]),
            ]
            for arm in candidates:
                rows += [dict(row, corpus=corpus)
                         for row in C.evaluate(arm, bench, r["k"], r["budget"], seed=seed)]
                if isinstance(arm, Timed) and arm.call_ms:
                    cost.setdefault(arm.name, []).extend(arm.call_ms)
            ask.save()
        print(f"  systems seed {seed} done ({len(ask.data)} cached calls)", flush=True)

    M.write_jsonl(out / "systems.jsonl", rows)
    want = {"main": ("all", "ambiguous"), "hard": ("answerable", "unanswerable")}
    result = {
        "summary": {f"{c}/{a}": M.summarize(rs, want[c], ci=False)
                    for (c, a), rs in M.group(rows, "corpus", "arm").items()},
        "request_path_model_ms": {k: {f"p{p}": M.percentile(v, p) for p in (50, 99)}
                                  for k, v in cost.items()},
        "model": scfg["model"], "seeds": seeds, "cached_calls": len(ask.data)}
    C.write_json(out / "systems.json", result)
    return result
