"""Identity resolution and abstention on the serving path.

Keyed supersession decides which value of a slot is current. It says nothing
about two failures that survive it: a block that carries a fact about a
different person whose name matches the surface form in the request, and a
block that carries somebody's value when the store holds none for the person
asked. Both are decisions about *which entity* the request concerns and
*whether the store has that entity's value*, so both are made on the ranked
list before selection, with no model call.

    resolve()        posterior over the entities a surface form can denote
    IdentityArm      re-weights the ranked list by that posterior
    SlotAbstain      empty block unless some fact states the queried slot for
                     the resolved entity (closed slot vocabulary)
    MarginAbstain    empty block unless the top fact clears a score margin
                     (open vocabulary; the portable fallback)

A hard participant filter is the degenerate case of `IdentityArm` that puts
all mass on the interlocutor, which is why it deletes facts about third
parties. The posterior keeps them, because the entity graph links a subject
to the people it is discussed with.
"""

from __future__ import annotations

import math
import re
from typing import Dict, List, Sequence, Tuple

import arms as A
import extractor as X
import pfm

# Trailing cue -> slot, tried before the noun, because room and meeting share
# their nouns ("the standup with Alex is in" vs "... is at").
_CUES = ((r"\bis in\s*$", "room"), (r"\bmoved to\s*$", "room"),
         (r"\b(?:at|to)\s*$", "meeting"))
_NOUNS = (("deadline", "deadline"), ("due date", "deadline"), ("launch", "launch"),
          ("cutover", "launch"), ("day rate", "rate"), ("budget cap", "budget"))


def slot_of_query(prefix: str) -> str:
    """Slot type a request asks for, from its noun and trailing cue. The rule
    covers the benchmark's six slots and nothing else; `MarginAbstain` is the
    variant that does not need a slot vocabulary."""
    low = prefix.lower().strip()
    for noun, slot in _NOUNS:
        if noun in low:
            return slot
    for cue, slot in _CUES:
        if re.search(cue, low):
            return slot
    return ""


def candidates(store: pfm.PFM, prefix: str) -> List[str]:
    """Entities an ambiguous mention in the request could denote. A name token
    of the request is a mention; it is ambiguous when several stored entities
    answer to it, as a first name does. Tokens that pick out one entity, such
    as a full project name, are left alone, so the posterior below never
    touches a request that has nothing to resolve."""
    toks = {t for t in pfm.tokenize(prefix)
            if t.isalpha() and len(t) > 1 and t not in pfm.STOPWORDS}
    by_token: Dict[str, set] = {}
    for e in store.entity_facts:
        for t in pfm.tokenize(e):
            if t in toks and t not in pfm.STOPWORDS:
                by_token.setdefault(t, set()).add(e)
    return sorted({e for es in by_token.values() if len(es) > 1 for e in es})


def alias_groups(cands: Sequence[str]) -> List[List[str]]:
    """Group candidate strings that name the same entity. The extractor emits
    both "halcyon" and "the halcyon" for one project, and those are aliases,
    not rivals: one string's tokens contain the other's. Two people who share a
    first name are rivals, because neither name contains the other."""
    groups: List[set] = []
    for e in cands:
        toks = set(pfm.tokenize(e))
        alias = lambda o: toks <= set(pfm.tokenize(o)) or set(pfm.tokenize(o)) <= toks
        hit = next((g for g in groups if any(alias(o) for o in g)), None)
        if hit is None:
            hit = set()
            groups.append(hit)
        hit.add(e)
    return [sorted(g) for g in groups]


def resolve(store: pfm.PFM, prefix: str, partners: Sequence[str], now: float,
            w: Tuple[float, float, float] = (1.0, 1.0, 0.25),
            temperature: float = 0.5) -> Dict[str, float]:
    """Posterior over the candidate entities of a request, from three pieces
    of evidence that cost no model call: whether the candidate is the
    interlocutor, how strongly the graph links it to the interlocutor, and
    how recently the store saw it. Returns {} when the mention is
    unambiguous, which leaves the ranking untouched."""
    groups = alias_groups(candidates(store, prefix))
    if len(groups) < 2:
        return {}
    w_part, w_graph, w_rec = w
    parts = [p.lower() for p in partners]
    scores = {}
    for group in groups:
        e = max(group, key=len)
        link = 0.0
        for p in parts:
            nbrs = store.graph.adj.get(p, {})
            total = sum(c.read(store.graph.log_gamma, now) for c in nbrs.values())
            if total > 0:
                link += sum(nbrs[a].read(store.graph.log_gamma, now)
                            for a in group if a in nbrs) / total
        seen = max((f.last_seen for f in store.facts.values()
                    if f.active and set(group) & set(f.entities)), default=None)
        rec = math.exp(store.rec_log_gamma * (now - seen)) if seen is not None else 0.0
        hit = any(a in parts for a in group)
        scores[tuple(group)] = w_part * hit + w_graph * link + w_rec * rec
    top = max(scores.values())
    exp = {g: math.exp((v - top) / temperature) for g, v in scores.items()}
    z = sum(exp.values())
    return {alias: v / z for g, v in exp.items() for alias in g}


class IdentityArm(A.Arm):
    """Multiply each fact's score by the posterior of the candidate entity it
    is about. `hard=True` keeps only the argmax, which is the filter rule
    stated as a posterior."""

    def __init__(self, inner: A.Arm, store: pfm.PFM, hard: bool = False, floor: float = 0.0):
        self.inner, self.store, self.hard, self.floor = inner, store, hard, floor
        self.name = f"{inner.name}|identity{'_hard' if hard else ''}"

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        post = resolve(self.store, prefix, partners, now)
        if not post:
            return ranked
        best = max(post, key=post.get)
        out = []
        for f, s in ranked:
            mine = [e for e in f.entities if e in post]
            if not mine:                       # not about any candidate: untouched
                out.append((f, s))
                continue
            p = max(post[e] for e in mine)
            if self.hard:
                if best in mine:
                    out.append((f, s))
            elif p >= self.floor:
                out.append((f, s * p))
        return sorted(out, key=lambda fs: (-fs[1], fs[0].fact_id))


class SlotAbstain(A.Arm):
    """Return nothing unless some fact states the queried slot type for a
    candidate entity that clears `tau`. Retrieval with a fixed k cannot
    report an empty store; this is the smallest change that lets it."""

    def __init__(self, inner: A.Arm, store: pfm.PFM, tau: float = 0.5, keep: int = 6):
        self.inner, self.store, self.tau, self.keep = inner, store, tau, keep
        self.name = f"{inner.name}|abstain_slot@{tau}"

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        want = slot_of_query(prefix)
        if not want:
            return ranked
        post = resolve(self.store, prefix, partners, now)
        keep = []
        for f, s in ranked[:self.keep]:
            if X.detect_slot(f.text)[0] != want:
                continue
            mine = [e for e in f.entities if e in post] if post else []
            if post and (not mine or max(post[e] for e in mine) < self.tau):
                continue
            keep.append((f, s))
        return keep


class MarginAbstain(A.Arm):
    """Open-vocabulary gate: keep the ranked list only when the top fact
    scores at least `tau` times the mean of the shortlist and shares at least
    `overlap` of the request's content terms. Needs no slot inventory, so it
    is the variant that transfers to a corpus we did not generate."""

    def __init__(self, inner: A.Arm, tau: float = 2.0, overlap: float = 0.34):
        self.inner, self.tau, self.overlap = inner, tau, overlap
        self.name = f"{inner.name}|abstain_margin@{tau}"

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        if not ranked:
            return ranked
        scores = [s for _, s in ranked]
        mean = sum(scores) / len(scores)
        terms = {t for t in pfm.tokenize(prefix)
                 if t not in pfm.STOPWORDS and len(t) > 1 and t.isalpha()}
        hit = {t for t in terms if t in pfm.tokenize(ranked[0][0].text)}
        if mean > 0 and scores[0] < self.tau * mean:
            return []
        if terms and len(hit) / len(terms) < self.overlap:
            return []
        return ranked


class ContextAffinity(A.Arm):
    """Resolve identity by neighbourhood instead of by name.

    `resolve` separates two stored entities that carry the same first name and
    differ in their full name. Real corpora are harder: both speakers named
    John in LoCoMo are the string "john", so no surface form tells them apart
    and no posterior over entity strings can. What does tell them apart is who
    each is discussed with, which the co-occurrence graph already records. A
    fact is scored by the decayed affinity between its own entities and the
    interlocutor, so a fact from a conversation the interlocutor never took
    part in is demoted even when it names the same person."""

    def __init__(self, inner: A.Arm, store: pfm.PFM, floor: float = 0.1):
        self.inner, self.store, self.floor = inner, store, floor
        self.name = f"{inner.name}|context_affinity"

    def affinity(self, entities: Sequence[str], parts: Sequence[str], now: float) -> float:
        g, best = self.store.graph, 0.0
        for p in parts:
            nbrs = g.adj.get(p, {})
            total = sum(c.read(g.log_gamma, now) for c in nbrs.values())
            if total <= 0:
                continue
            for e in entities:
                if e in nbrs:
                    best = max(best, nbrs[e].read(g.log_gamma, now) / total)
        return best

    def rank(self, prefix, partners, now):
        parts = [p.lower() for p in partners]
        return sorted(((f, s * max(self.floor, self.affinity(f.entities, parts, now)))
                       for f, s in self.inner.rank(prefix, partners, now)),
                      key=lambda fs: (-fs[1], fs[0].fact_id))
