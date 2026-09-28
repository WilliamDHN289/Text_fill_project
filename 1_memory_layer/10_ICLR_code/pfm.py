"""Personal Fact Memory (PFM): reference implementation.

Construction path
    ingest(text, participants, now)
        extract drafts -> keyed supersession / value-aware near-duplicate
        admission -> fielded BM25F index + entity co-occurrence graph.
    Each document is committed in one critical section and bumps
    `store.version`, so a reader never observes a closed predecessor
    without its successor (or the reverse).

Serving path
    rank(context, participants, now)    shortlist of (fact, score)
    select(ranked, k, budget)           greedy prefix rule
    format_block(facts)                 serialized memory block
    Server.read() / Server.fresh()      snapshot read / fresh retrieval with
                                        a waiting budget and cancellation

Every parameter comes from the `pfm` block of config.yaml. Standard library
only; deterministic given the corpus.
"""

from __future__ import annotations

import heapq
import itertools
import math
import re
import queue
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

DAY = 86_400.0

_WORD_RE = re.compile(r"[a-z0-9_\-'@.]+|[^\sa-z0-9]")
STOPWORDS = frozenset(
    """a an and are as at be but by for from has have i if in into is it its me my
    of on or our so that the their them then there these they this to was we were
    what when which who will with would you your not no yes do does did been""".split())
_MONTH_RE = re.compile(r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b")


def tokenize(text: str) -> List[str]:
    return _WORD_RE.findall(text.lower())


def value_tokens(text: str) -> frozenset:
    """Value-bearing tokens: anything with a digit (times, dates, amounts,
    room codes) plus month names."""
    low = text.lower()
    return frozenset([t for t in tokenize(low) if any(c.isdigit() for c in t)]
                     + _MONTH_RE.findall(low))


def half_life_log_gamma(days: float) -> float:
    return -math.log(2.0) / (days * DAY)


class Cancelled(Exception):
    """Raised inside a fresh retrieval whose waiting budget has expired."""


@dataclass
class Decayed:
    """value(t) = value * exp(log_gamma * (t - stamp)), materialized on read."""
    value: float = 0.0
    stamp: float = 0.0

    def read(self, log_gamma: float, now: float) -> float:
        return self.value * math.exp(log_gamma * (now - self.stamp)) if self.value else 0.0

    def bump(self, log_gamma: float, now: float, amount: float = 1.0) -> None:
        self.value = self.read(log_gamma, now) + amount
        self.stamp = now


@dataclass
class Draft:
    """Extractor output; the store assigns ids and times."""
    text: str
    entities: Tuple[str, ...] = ()
    key: Optional[Tuple[str, str]] = None


@dataclass
class Fact:
    fact_id: int
    text: str
    entities: Tuple[str, ...]
    participants: Tuple[str, ...]
    key: Optional[Tuple[str, str]]
    active_from: float                      # a_f
    active_until: Optional[float] = None    # b_f; None means infinity
    last_seen: float = 0.0                  # creation or exact re-observation
    usage: Decayed = field(default_factory=Decayed)

    @property
    def active(self) -> bool:
        return self.active_until is None


# ---------------------------------------------------------------------------
# Fielded BM25F index over active facts
# ---------------------------------------------------------------------------

class BM25FIndex:
    """Simple BM25F: field term frequencies are combined with field weights
    into one pseudo-document, then scored with a single (k1, b)."""

    def __init__(self, field_weights: Dict[str, float], k1: float, b: float):
        self.w, self.k1, self.b = field_weights, k1, b
        self.postings: Dict[str, Dict[int, float]] = defaultdict(dict)
        self.doc_len: Dict[int, float] = {}
        self.total_len = 0.0

    def _tf(self, f: Fact) -> Dict[str, float]:
        tf: Dict[str, float] = defaultdict(float)
        fields = {"text": [f.text], "entities": f.entities, "participants": f.participants}
        for name, values in fields.items():
            if self.w[name]:
                for t in itertools.chain.from_iterable(map(tokenize, values)):
                    tf[t] += self.w[name]
        return tf

    def add(self, f: Fact) -> None:
        tf = self._tf(f)
        self.doc_len[f.fact_id] = sum(tf.values())
        self.total_len += self.doc_len[f.fact_id]
        for t, x in tf.items():
            self.postings[t][f.fact_id] = x

    def remove(self, f: Fact) -> None:
        if f.fact_id not in self.doc_len:
            return
        self.total_len -= self.doc_len.pop(f.fact_id)
        for t in self._tf(f):
            plist = self.postings.get(t)
            if plist is not None:
                plist.pop(f.fact_id, None)
                if not plist:
                    del self.postings[t]

    def idf(self, term: str) -> float:
        df = len(self.postings.get(term, ()))
        n = len(self.doc_len)
        return math.log(1.0 + (n - df + 0.5) / (df + 0.5)) if df else 0.0

    def score(self, query: Dict[str, float], cancel=None) -> Dict[int, float]:
        if not self.doc_len:
            return {}
        avgdl = self.total_len / len(self.doc_len)
        acc: Dict[int, float] = defaultdict(float)
        for term, qw in query.items():
            if cancel is not None and cancel.is_set():
                raise Cancelled
            plist = self.postings.get(term)
            if not plist:
                continue
            idf = self.idf(term)
            for fid, tf in plist.items():
                norm = self.k1 * (1.0 - self.b + self.b * self.doc_len[fid] / avgdl)
                acc[fid] += qw * idf * tf * (self.k1 + 1.0) / (tf + norm)
        return acc


# ---------------------------------------------------------------------------
# Entity co-occurrence graph
# ---------------------------------------------------------------------------

class EntityGraph:
    """Decayed co-occurrence counts w_eg(t). Edges come from every admitted
    fact (superseded ones included) and are never removed on supersession."""

    def __init__(self, half_life_days: float, max_degree: int):
        self.log_gamma = half_life_log_gamma(half_life_days)
        self.max_degree = max_degree
        self.adj: Dict[str, Dict[str, Decayed]] = defaultdict(dict)

    def observe(self, nodes: Sequence[str], now: float) -> None:
        for a, b in itertools.combinations(sorted(set(nodes)), 2):
            for u, v in ((a, b), (b, a)):
                nbrs = self.adj[u]
                if v in nbrs or len(nbrs) < self.max_degree:
                    nbrs.setdefault(v, Decayed()).bump(self.log_gamma, now)

    def activation(self, seeds: Sequence[str], now: float, damping: float,
                   max_neighbors: int) -> Dict[str, float]:
        """Seeds get activation 1. A non-seed neighbor g gets
        damping * sum_e w_eg / sum_v w_ev; only the top `max_neighbors` are kept."""
        act = {s: 1.0 for s in seeds}
        boost: Dict[str, float] = defaultdict(float)
        for s in act:
            weights = {v: c.read(self.log_gamma, now) for v, c in self.adj.get(s, {}).items()}
            total = sum(weights.values())
            for v, w in weights.items():
                if total > 0 and v not in act:
                    boost[v] += damping * w / total
        act.update(heapq.nlargest(max_neighbors, boost.items(), key=lambda kv: kv[1]))
        return act

    def prune(self, now: float, min_weight: float) -> None:
        for u in list(self.adj):
            nbrs = self.adj[u]
            for v in [v for v, c in nbrs.items() if c.read(self.log_gamma, now) < min_weight]:
                del nbrs[v]
            if not nbrs:
                del self.adj[u]


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

Extractor = Callable[[str], List[Draft]]


class PFM:
    def __init__(self, cfg: dict, extractor: Extractor):
        self.cfg = cfg
        self.extractor = extractor
        s, g = cfg["scoring"], cfg["graph"]
        self.index = BM25FIndex(s["field_weights"], s["bm25_k1"], s["bm25_b"])
        self.graph = EntityGraph(g["half_life_days"], g["max_degree"])
        self.rec_log_gamma = half_life_log_gamma(s["recency_half_life_days"])
        self.use_log_gamma = half_life_log_gamma(s["usage_half_life_days"])
        self.facts: Dict[int, Fact] = {}
        self.entity_facts: Dict[str, set] = defaultdict(set)
        self.key_owner: Dict[Tuple[str, str], int] = {}
        self.version = 0
        self.lock = threading.RLock()
        self._ids = itertools.count(1)

    # -- construction ------------------------------------------------------
    def ingest(self, text: str, participants: Sequence[str], now: float) -> List[Fact]:
        drafts = self.extractor(text)
        with self.lock:
            added = [f for d in drafts
                     if (f := self._admit(d, tuple(participants), now)) is not None]
            self.version += 1
        return added

    def _admit(self, d: Draft, participants: Tuple[str, ...], now: float) -> Optional[Fact]:
        """Keyed draft: exact repeat of the active value is a re-observation,
        anything else supersedes it, unless `order_by: event` and the active
        value was stated later. Keyless draft: absorbed only by a
        near-duplicate with identical value tokens."""
        inherited, late = Decayed(), False
        if d.key is not None:
            prev = self.facts.get(self.key_owner.get(d.key, -1))
            if prev is not None and prev.active:
                if prev.text.strip().lower() == d.text.strip().lower():
                    return self._reobserve(prev, now)
                if self.cfg["admission"]["order_by"] == "event" and now < prev.active_from:
                    late = True          # the active value was stated later; keep it
                else:
                    prev.active_until = now
                    self.index.remove(prev)
                    if self.cfg["admission"]["inherit_usage"]:
                        inherited = Decayed(prev.usage.value, prev.usage.stamp)
        else:
            dup = self._near_duplicate(d)
            if dup is not None:
                return self._reobserve(dup, now)

        f = Fact(next(self._ids), d.text, d.entities, participants, d.key,
                 active_from=now, active_until=now if late else None,
                 last_seen=now, usage=inherited)
        self.facts[f.fact_id] = f
        for e in f.entities:
            self.entity_facts[e].add(f.fact_id)
        if not late:                      # a late arrival is stored only as history
            self.index.add(f)
            if f.key is not None:
                self.key_owner[f.key] = f.fact_id
        self.graph.observe(f.entities + tuple(p.lower() for p in participants), now)
        return f

    def _near_duplicate(self, d: Draft) -> Optional[Fact]:
        adm = self.cfg["admission"]
        toks, vals = set(tokenize(d.text)), value_tokens(d.text)
        for fid in set().union(*(self.entity_facts.get(e, ()) for e in d.entities)):
            old = self.facts[fid]
            if not old.active:
                continue
            if adm["value_aware_dedup"] and value_tokens(old.text) != vals:
                continue
            old_toks = set(tokenize(old.text))
            if len(toks & old_toks) / len(toks | old_toks) >= adm["dedup_jaccard"]:
                return old
        return None

    def _reobserve(self, f: Fact, now: float) -> None:
        """Returns None: nothing new is admitted."""
        f.usage.bump(self.use_log_gamma, now)
        f.last_seen = now
        return None

    def ingest_draft(self, d: Draft, participants: Sequence[str], now: float) -> Optional[Fact]:
        """Admit one externally produced draft (used by model-driven updates)."""
        with self.lock:
            f = self._admit(d, tuple(participants), now)
            self.version += 1
        return f

    def supersede(self, target_id: int, d: Draft, participants: Sequence[str],
                  now: float) -> Optional[Fact]:
        """Close `target_id` and admit `d` in its place. Used by update
        decisions that come from outside the store, such as a model choosing
        UPDATE over ADD; keyed supersession is the in-store equivalent."""
        with self.lock:
            target = self.facts.get(target_id)
            if target is not None and target.active:
                self.close(target_id, now)
            f = self._admit(d, tuple(participants), now)
            self.version += 1
        return f

    def close(self, fact_id: int, now: float) -> bool:
        """Retire a fact without a replacement (a delete decision)."""
        with self.lock:
            f = self.facts.get(fact_id)
            if f is None or not f.active:
                return False
            f.active_until = now
            self.index.remove(f)
            if f.key is not None and self.key_owner.get(f.key) == f.fact_id:
                del self.key_owner[f.key]
            self.version += 1
            return True

    def mark_served(self, fact_ids: Sequence[int], now: float) -> None:
        """Usage feedback. Evaluations never call this, so usage is frozen."""
        with self.lock:
            for fid in fact_ids:
                if fid in self.facts:
                    self.facts[fid].usage.bump(self.use_log_gamma, now)

    def prune(self, now: float) -> int:
        """Drop keyless active facts whose recency x (1 + usage) falls below the
        threshold. The active owner of a key is exempt, so no slot loses its
        only active value; superseded facts stay as history."""
        p = self.cfg["prune"]
        with self.lock:
            doomed = [f for f in self.facts.values()
                      if f.active and f.key is None and self._retention(f, now) < p["min_score"]]
            for f in doomed:
                self.index.remove(f)
                del self.facts[f.fact_id]
                for e in f.entities:
                    self.entity_facts[e].discard(f.fact_id)
            self.graph.prune(now, p["graph_min_weight"])
            self.version += 1
        return len(doomed)

    def _retention(self, f: Fact, now: float) -> float:
        rec = math.exp(self.rec_log_gamma * (now - f.last_seen))
        return rec * (1.0 + f.usage.read(self.use_log_gamma, now))

    # -- serving -----------------------------------------------------------
    def build_query(self, context: str, participants: Sequence[str]) -> Dict[str, float]:
        """Positional decay lambda^d from the generation point, additive
        participant weight, then keep the top terms by weight x idf."""
        r = self.cfg["retrieval"]
        toks = tokenize(context)
        q: Dict[str, float] = defaultdict(float)
        for i, t in enumerate(toks):
            if t not in STOPWORDS and len(t) > 1:
                q[t] += r["positional_decay"] ** (len(toks) - 1 - i)
        if r["participant_weight"]:
            for t in itertools.chain.from_iterable(map(tokenize, participants)):
                if t not in STOPWORDS:
                    q[t] += r["participant_weight"]
        cap = r["max_query_terms"]
        if cap and len(q) > cap:
            q = dict(heapq.nlargest(cap, q.items(),
                                    key=lambda kv: kv[1] * max(self.index.idf(kv[0]), 1e-6)))
        return q

    def rank(self, context: str, participants: Sequence[str], now: float,
             cancel: Optional[threading.Event] = None) -> List[Tuple[Fact, float]]:
        """Eq. (score): BM25F * (eps + (1-eps) 2^(-age/T)) * (1 + eta h) + gamma assoc."""
        s, g = self.cfg["scoring"], self.cfg["graph"]
        with self.lock:
            query = self.build_query(context, participants)
            lex = self.index.score(query, cancel)
            assoc: Dict[int, float] = defaultdict(float)
            if s["graph_gamma"]:
                seeds = [t for t in query if t in self.entity_facts]
                if g["seed_participants"]:
                    seeds += [p.lower() for p in participants if p.lower() in self.entity_facts]
                for ent, a in self.graph.activation(seeds, now, g["damping"],
                                                    g["max_neighbors"]).items():
                    for fid in self.entity_facts.get(ent, ()):
                        assoc[fid] += a
            if cancel is not None and cancel.is_set():
                raise Cancelled
            eps = s["recency_floor"]
            scored = []
            for fid in lex.keys() | assoc.keys():
                f = self.facts.get(fid)
                if f is None or not f.active:
                    continue
                rec = eps + (1 - eps) * math.exp(self.rec_log_gamma * (now - f.last_seen))
                use = 1 + s["usage_eta"] * f.usage.read(self.use_log_gamma, now)
                score = lex.get(fid, 0.0) * rec * use + s["graph_gamma"] * assoc.get(fid, 0.0)
                if score > 0:
                    scored.append((f, score))
        return heapq.nlargest(self.cfg["retrieval"]["shortlist"], scored,
                              key=lambda fs: (fs[1], -fs[0].fact_id))

    def retrieve(self, context: str, participants: Sequence[str], now: float,
                 cancel: Optional[threading.Event] = None) -> "Snapshot":
        t0 = time.perf_counter()
        r = self.cfg["retrieval"]
        with self.lock:
            version = self.version
            ranked = self.rank(context, participants, now, cancel)
        facts = select([f for f, _ in ranked], r["k"], r["budget"])
        return Snapshot(tuple(facts), format_block(facts), context, tuple(participants),
                        requested_at=now, store_version=version,
                        built_wall=time.perf_counter(),
                        latency_ms=(time.perf_counter() - t0) * 1e3)

    def stats(self) -> Dict[str, int]:
        with self.lock:
            return {"facts": len(self.facts),
                    "active_facts": sum(f.active for f in self.facts.values()),
                    "index_terms": len(self.index.postings),
                    "graph_nodes": len(self.graph.adj),
                    "version": self.version}


# ---------------------------------------------------------------------------
# Prompt assembly (shared by every retrieval arm)
# ---------------------------------------------------------------------------

BLOCK_HEADER = "[Relevant memory]"


def fact_line(f: Fact) -> str:
    who = f", to {', '.join(f.participants)}" if f.participants else ""
    day = time.strftime("%Y-%m-%d", time.gmtime(f.active_from))
    return f"- ({day}{who}) {f.text}"


def select(ranked: Sequence[Fact], k: int, budget: int) -> List[Fact]:
    """Greedy prefix rule: take facts in rank order and STOP at the first one
    that would break |S| <= k or len(format_block(S)) <= budget. The budget
    counts the whole serialized block (header, attribution prefix, newlines)."""
    out, used = [], len(BLOCK_HEADER)
    for f in ranked[:k]:
        cost = 1 + len(fact_line(f))
        if used + cost > budget:
            break
        out.append(f)
        used += cost
    return out


def format_block(facts: Sequence[Fact]) -> str:
    return "\n".join([BLOCK_HEADER] + [fact_line(f) for f in facts]) if facts else ""


# ---------------------------------------------------------------------------
# Serving protocol
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Snapshot:
    facts: Tuple[Fact, ...]
    block: str
    context: str
    participants: Tuple[str, ...]
    requested_at: float          # logical request time the retrieval scored against
    store_version: int           # store.version read at retrieval start
    built_wall: float            # perf_counter() when the result was produced
    latency_ms: float


EMPTY_SNAPSHOT = Snapshot((), "", "", (), 0.0, -1, 0.0, 0.0)


class Server:
    """Snapshot mode reads one reference. Fresh mode hands the request to a
    long-lived worker and waits at most `wait_s`, then cancels it and falls
    back to the snapshot. The request thread never takes the store lock.

    Workers are started once, at construction. An earlier version started a
    thread per request, and `Thread.start()` blocks the caller until the new
    thread runs, which under interpreter-lock contention cost a median of
    3~ms and a maximum of 12~ms -- more than the waiting budget itself, and a
    term the bound of Proposition 2 does not name. Handing the request to a
    queue costs microseconds instead. There is more than one worker because a
    single one puts a request behind whatever cancelled retrieval is still
    draining, which is head-of-line blocking the bound does not name either."""

    def __init__(self, store: PFM, workers: int = 4):
        self.store = store
        self._snapshot = EMPTY_SNAPSHOT
        self._jobs: "queue.Queue" = queue.Queue()
        self._workers = [threading.Thread(target=self._serve_jobs, daemon=True)
                         for _ in range(workers)]
        for w in self._workers:
            w.start()

    def _serve_jobs(self) -> None:
        while True:
            job = self._jobs.get()
            context, participants, now, cancel, box, done = job
            try:
                if not cancel.is_set():
                    box.append(self.store.retrieve(context, participants, now, cancel))
            except Cancelled:
                pass
            finally:
                done.set()

    def publish(self, context: str, participants: Sequence[str], now: float) -> Snapshot:
        snap = self.store.retrieve(context, participants, now)
        self._snapshot = snap                   # single reference assignment
        return snap

    def read(self) -> Snapshot:
        return self._snapshot

    def fresh(self, context: str, participants: Sequence[str], now: float,
              wait_s: float, trace: Optional[Dict[str, float]] = None
              ) -> Tuple[Snapshot, str]:
        """`trace` collects the pieces the waiting bound is made of, in ms:
        `spawn` to start the worker, `wait` spent in the timed wait, `after`
        to cancel and read the reference. The scheduling term of
        Proposition 2 is what `spawn` and the overshoot of `wait` beyond
        `wait_s` measure; a sleep timed elsewhere in the process does not
        bound them."""
        box: List[Snapshot] = []
        done, cancel = threading.Event(), threading.Event()
        t0 = time.perf_counter()
        self._jobs.put((context, participants, now, cancel, box, done))
        t1 = time.perf_counter()
        got = done.wait(wait_s)
        t2 = time.perf_counter()
        if got and box:
            result, source = box[0], "fresh"
        else:
            cancel.set()
            result, source = self._snapshot, "snapshot"
        if trace is not None:
            trace.update(submit=(t1 - t0) * 1e3, wait=(t2 - t1) * 1e3,
                         after=(time.perf_counter() - t2) * 1e3,
                         overshoot=max(0.0, (t2 - t1) - wait_s) * 1e3 if not got else 0.0)
        return result, source
