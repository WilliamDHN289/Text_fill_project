"""
DPFM: Dual-Path Fact Memory
===========================
A low-latency *fact* memory layer for real-time text completion.

Successor of DPHM (../3_dphm/dphm.py). DPHM stored *language habits*
(personal n-grams) and fused them with the base LM at the score level.
DPFM stores *facts* (what past documents said, to whom, when) and injects
retrieved facts into the LLM prompt. The dual-path architecture is kept;
the payload and the retrieval machinery change.

Pipeline
--------
    write:  document --(cold path)--> extract facts --> dedup/supersede
            --> BM25F inverted index + entity co-occurrence graph
    read:   typing context --(parallel with text_fill)--> focus-term query
            --> BM25F top-k  x recency x heat  + entity-graph association
            --> prompt block

Design principles
-----------------
1. Hot path / cold path decoupling (kept from DPHM):
   - Read path is pure in-memory inverted-index lookups over a *personal*
     corpus (10^3..10^5 facts). No embeddings, no ANN, no LLM call.
     Target p99 < 5 ms, so it can run in parallel with (or even inside)
     the text_fill request without hurting latency.
   - Write path (fact extraction, dedup, graph update, pruning) is
     asynchronous, queue-fed, and may be arbitrarily slow.

2. Retrieval is lexical-first, association-second:
   - BM25F (Robertson et al. 2004) over weighted fields
     {text, entities, participants}: exact names/terms are what an
     autocomplete continuation actually needs to copy into the text.
     Zep/Graphiti (arXiv:2501.13956) ships BM25 as a co-equal retriever
     next to cosine similarity, fused by RRF -- lexical-only is a sound
     operating point, embeddings are an additive upgrade, not a base.
   - An entity co-occurrence graph gives cheap associative recall
     (HippoRAG, arXiv:2405.14831, replaces its Personalized PageRank
     with truncated 1-hop spreading activation).

3. Facts are atomic, temporal, and self-correcting:
   - Atomic prompt-ready sentences with entity links (A-MEM,
     arXiv:2502.12110; Mem0, arXiv:2504.19413).
   - Bi-temporal validity: a superseding fact *invalidates* its
     predecessor instead of deleting it (Zep/Graphiti edge model).
   - Recency decay + usage 'heat' (MemoryOS, arXiv:2506.06326) govern
     ranking and forgetting; accepted completions reinforce the facts
     that produced them (closing the consolidation loop, as in DPHM).

4. Parallelism with text_fill:
   - Speculative prefetch (kept from DPHM): retrieval is triggered on
     word boundaries / pauses, publishes an immutable snapshot; prompt
     assembly reads the latest snapshot with one attribute load.
   - Deadline race: `retrieve_with_deadline` races a fresh retrieval
     against a time budget and falls back to the stale snapshot.

5. Embeddings as backup only: a pluggable `semantic_fn` may run inside
   the prefetch worker; its results are fused with the lexical list via
   Reciprocal Rank Fusion. The deadline path never waits for it.

Stdlib-only, embeddable in an IME / editor plugin / web backend.
"""

from __future__ import annotations

import heapq
import itertools
import math
import queue
import re
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

Token = str

_WORD_RE = re.compile(r"[A-Za-z0-9_\-'@.]+|[一-鿿]|[^\sA-Za-z0-9一-鿿]")
_CJK_RE = re.compile(r"[一-鿿]")

_STOPWORDS = frozenset(
    """a an and are as at be but by for from has have i if in into is it its me my
    of on or our so that the their them then there these they this to was we were
    what when which who will with would you your not no yes do does did been
    的 了 是 在 我 有 和 就 不 人 都 一 一个 上 也 很 到 说 要 去 你 会 着 没有 看 好
    这 那 他 她 它 们 与 及 或 而 被 把 对 从 向 之 于 其""".split()
)


def tokenize(text: str) -> List[Token]:
    """Lightweight bilingual tokenizer (same contract as DPHM's):
    English words stay whole, CJK is split per character."""
    return _WORD_RE.findall(text.lower())


def index_terms(text: str) -> List[Token]:
    """Tokens to index/query with. CJK additionally emits character
    *bigrams* so BM25 gets discriminative CJK terms (unigram chars are
    nearly stopwords in Chinese)."""
    toks = tokenize(text)
    out: List[Token] = []
    for i, t in enumerate(toks):
        out.append(t)
        if _CJK_RE.fullmatch(t) and i + 1 < len(toks) and _CJK_RE.fullmatch(toks[i + 1]):
            out.append(t + toks[i + 1])
    return out


# ---------------------------------------------------------------------------
# 1. Lazily decayed counter (kept from DPHM)
# ---------------------------------------------------------------------------

@dataclass
class _DecayedCount:
    """value(t) = value * exp(log_gamma * (t - stamp)); decay materializes
    only on read, writes stay O(1)."""
    value: float = 0.0
    stamp: float = 0.0

    def read(self, log_gamma: float, now: float) -> float:
        if self.value == 0.0:
            return 0.0
        return self.value * math.exp(log_gamma * (now - self.stamp))

    def bump(self, log_gamma: float, now: float, amount: float = 1.0) -> None:
        self.value = self.read(log_gamma, now) + amount
        self.stamp = now


def _log_gamma(half_life_s: float) -> float:
    return -math.log(2.0) / half_life_s


# ---------------------------------------------------------------------------
# 2. Fact record
# ---------------------------------------------------------------------------

@dataclass
class Fact:
    """One atomic, prompt-ready fact.

    kind: 'episodic'  -- tied to one source document ("email to Alice said X")
          'semantic'  -- consolidated, source-independent ("Phoenix ships Q3")
          'profile'   -- stable user/world attributes ("my manager is Bo")
    key:  optional slot identity, e.g. ('phoenix', 'deadline'). A new fact
          with the same key *supersedes* (bi-temporally invalidates) the old.
    """
    fact_id: int
    text: str
    entities: Tuple[str, ...]
    participants: Tuple[str, ...]
    source_id: str
    kind: str = "episodic"
    key: Optional[Tuple[str, str]] = None
    created_at: float = 0.0
    valid_from: float = 0.0
    invalid_at: Optional[float] = None      # set when superseded
    last_reinforced: float = 0.0            # created / re-observed / accepted
    heat: _DecayedCount = field(default_factory=_DecayedCount)

    @property
    def valid(self) -> bool:
        return self.invalid_at is None


@dataclass
class FactDraft:
    """What an extractor emits; the store assigns ids and timestamps."""
    text: str
    entities: Tuple[str, ...] = ()
    kind: str = "episodic"
    key: Optional[Tuple[str, str]] = None


# ---------------------------------------------------------------------------
# 3. BM25F inverted index (incremental, in-memory)
# ---------------------------------------------------------------------------

class BM25FIndex:
    """'Simple BM25F': per-field term frequencies are combined into one
    weighted tf at write time, then scored with plain BM25 saturation
    (Robertson & Zaragoza 2009, sec. 3.5). Incremental add/remove.

    Scale assumption: personal corpus, N in the 10^3..10^5 range, so
    term-at-a-time accumulation over the (short) posting lists of ~12
    query terms costs well under a millisecond.
    """

    FIELD_WEIGHTS = {"text": 1.0, "entities": 2.5, "participants": 2.0}

    def __init__(self, k1: float = 1.2, b: float = 0.75):
        self.k1, self.b = k1, b
        self.postings: Dict[Token, Dict[int, float]] = defaultdict(dict)
        self.doc_len: Dict[int, float] = {}
        self.total_len = 0.0

    @property
    def n_docs(self) -> int:
        return len(self.doc_len)

    def _weighted_tf(self, fact: Fact) -> Dict[Token, float]:
        wtf: Dict[Token, float] = defaultdict(float)
        fields = {
            "text": index_terms(fact.text),
            "entities": [t for e in fact.entities for t in index_terms(e)],
            "participants": [t for p in fact.participants for t in index_terms(p)],
        }
        for name, toks in fields.items():
            w = self.FIELD_WEIGHTS[name]
            for t in toks:
                wtf[t] += w
        return wtf

    def add(self, fact: Fact) -> None:
        wtf = self._weighted_tf(fact)
        dl = sum(wtf.values())
        self.doc_len[fact.fact_id] = dl
        self.total_len += dl
        for t, f in wtf.items():
            self.postings[t][fact.fact_id] = f

    def remove(self, fact: Fact) -> None:
        if fact.fact_id not in self.doc_len:
            return
        self.total_len -= self.doc_len.pop(fact.fact_id)
        for t in self._weighted_tf(fact):
            plist = self.postings.get(t)
            if plist is not None:
                plist.pop(fact.fact_id, None)
                if not plist:
                    del self.postings[t]

    def idf(self, term: Token) -> float:
        df = len(self.postings.get(term, ()))
        if df == 0:
            return 0.0
        return math.log(1.0 + (self.n_docs - df + 0.5) / (df + 0.5))

    def score_all(self, query: Dict[Token, float]) -> Dict[int, float]:
        """Term-at-a-time accumulation: {fact_id: bm25f score}."""
        if not self.doc_len:
            return {}
        avgdl = self.total_len / len(self.doc_len)
        acc: Dict[int, float] = defaultdict(float)
        for term, qw in query.items():
            plist = self.postings.get(term)
            if not plist:
                continue
            idf = self.idf(term)
            for fid, wtf in plist.items():
                norm = self.k1 * (1.0 - self.b + self.b * self.doc_len[fid] / avgdl)
                acc[fid] += qw * idf * wtf * (self.k1 + 1.0) / (wtf + norm)
        return acc


# ---------------------------------------------------------------------------
# 4. Entity co-occurrence graph (HippoRAG-lite associative recall)
# ---------------------------------------------------------------------------

class EntityGraph:
    """Decayed entity co-occurrence graph. `expand` runs truncated
    spreading activation (1 hop by default) from seed entities -- the
    poor man's Personalized PageRank, O(seeds x avg_degree)."""

    def __init__(self, half_life_s: float = 30 * 24 * 3600.0, max_degree: int = 64):
        self.log_gamma = _log_gamma(half_life_s)
        self.max_degree = max_degree
        self.adj: Dict[str, Dict[str, _DecayedCount]] = defaultdict(dict)

    def observe(self, entities: Sequence[str], now: float) -> None:
        uniq = sorted(set(entities))
        for a, b in itertools.combinations(uniq, 2):
            for u, v in ((a, b), (b, a)):
                nbrs = self.adj[u]
                if v not in nbrs and len(nbrs) >= self.max_degree:
                    continue  # degree cap keeps expansion bounded
                nbrs.setdefault(v, _DecayedCount()).bump(self.log_gamma, now)

    def expand(self, seeds: Iterable[str], now: float,
               damping: float = 0.5, top: int = 12) -> Dict[str, float]:
        """activation[entity]; seeds get 1.0, neighbors get damped,
        edge-weight-normalized mass."""
        act: Dict[str, float] = {}
        for s in seeds:
            act[s] = max(act.get(s, 0.0), 1.0)
        boosts: Dict[str, float] = defaultdict(float)
        for s in list(act):
            nbrs = self.adj.get(s)
            if not nbrs:
                continue
            weights = {v: c.read(self.log_gamma, now) for v, c in nbrs.items()}
            total = sum(weights.values())
            if total <= 0.0:
                continue
            for v, w in weights.items():
                if v not in act:
                    boosts[v] += damping * w / total
        for v, a in heapq.nlargest(top, boosts.items(), key=lambda kv: kv[1]):
            act[v] = max(act.get(v, 0.0), a)
        return act

    def prune(self, now: float, min_weight: float = 0.05) -> None:
        for u in list(self.adj):
            nbrs = self.adj[u]
            for v in [v for v, c in nbrs.items()
                      if c.read(self.log_gamma, now) < min_weight]:
                del nbrs[v]
            if not nbrs:
                del self.adj[u]


# ---------------------------------------------------------------------------
# 5. Rule-based fact extractor (default; swap in an LLM extractor cold-side)
# ---------------------------------------------------------------------------

_SENT_SPLIT_RE = re.compile(r"(?<=[.!?。！？])\s+|\n+")
_EMAIL_RE = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b")
_DATE_RE = re.compile(
    r"\b\d{4}-\d{1,2}-\d{1,2}\b"
    r"|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b"
    r"|\d{1,2}月\d{1,2}[日号]")
_CAPSEQ_RE = re.compile(r"\b[A-Z][\w\-]*(?:\s+[A-Z][\w\-]*)*")
# Sentences worth remembering usually carry commitments, decisions, or state.
_SIGNAL_RE = re.compile(
    r"\b(?:will|agreed|decided|due|deadline|scheduled|moved|confirmed|prefers?|"
    r"is|are|was|needs?|owns?|sent|meeting)\b"
    r"|定于|决定|同意|截止|改到|安排|负责|需要|会议|发送|偏好", re.IGNORECASE)


def make_rule_extractor(gazetteer: Iterable[str] = ()) -> Callable[[str], List[FactDraft]]:
    """Entity detection: emails, dates, capitalized sequences, plus a
    user-supplied gazetteer (required for CJK names/projects, which carry
    no capitalization signal). Keeps sentences that mention >=1 entity or
    a digit AND show a factual signal verb."""
    gaz = {g.lower(): g for g in gazetteer}

    def extract(text: str) -> List[FactDraft]:
        drafts: List[FactDraft] = []
        for sent in _SENT_SPLIT_RE.split(text):
            sent = sent.strip()
            if not 8 <= len(sent) <= 300:
                continue
            ents: Set[str] = set()
            ents.update(m.group(0).lower() for m in _EMAIL_RE.finditer(sent))
            ents.update(m.group(0).lower() for m in _DATE_RE.finditer(sent))
            for m in _CAPSEQ_RE.finditer(sent):
                cand = m.group(0)
                # drop sentence-initial capitalized stopwords ("The", "We"...)
                if m.start() == 0 and cand.lower() in _STOPWORDS and " " not in cand:
                    continue
                if cand.lower() not in _STOPWORDS:
                    ents.add(cand.lower())
            low = sent.lower()
            ents.update(g for g in gaz if g in low)
            has_signal = bool(_SIGNAL_RE.search(sent))
            has_anchor = bool(ents) or any(c.isdigit() for c in sent)
            if has_anchor and has_signal:
                drafts.append(FactDraft(text=sent, entities=tuple(sorted(ents))))
        return drafts

    return extract


# ---------------------------------------------------------------------------
# 6. Retrieval snapshot (what the prompt assembler consumes)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class RetrievalSnapshot:
    facts: Tuple[Fact, ...]
    prompt_block: str
    query_terms: Tuple[Token, ...]
    created_at: float
    latency_ms: float
    stale: bool = False

EMPTY_SNAPSHOT = RetrievalSnapshot((), "", (), 0.0, 0.0, stale=True)


# ---------------------------------------------------------------------------
# 7. DualPathFactMemory
# ---------------------------------------------------------------------------

class DualPathFactMemory:
    """Facade. Read path: `retrieve` / `retrieve_with_deadline` /
    `poke_prefetch`+`snapshot`. Write path: `observe_document` (async) or
    `ingest_document` (sync, for tests). Feedback: `mark_used`."""

    def __init__(
        self,
        extractor: Optional[Callable[[str], List[FactDraft]]] = None,
        semantic_fn: Optional[Callable[[str, int], List[Tuple[str, float]]]] = None,
        recency_half_life_s: float = 30 * 24 * 3600.0,
        heat_half_life_s: float = 14 * 24 * 3600.0,
        recency_floor: float = 0.15,
        heat_eta: float = 0.35,
        assoc_gamma: float = 0.8,
        max_query_terms: int = 12,
        query_pos_decay: float = 0.95,
        dedup_jaccard: float = 0.8,
        prompt_char_budget: int = 800,
        prefetch_debounce_s: float = 0.15,
    ):
        self.extractor = extractor or make_rule_extractor()
        self.semantic_fn = semantic_fn
        self.recency_log_gamma = _log_gamma(recency_half_life_s)
        self.heat_log_gamma = _log_gamma(heat_half_life_s)
        self.recency_floor = recency_floor
        self.heat_eta = heat_eta
        self.assoc_gamma = assoc_gamma
        self.max_query_terms = max_query_terms
        self.query_pos_decay = query_pos_decay
        self.dedup_jaccard = dedup_jaccard
        self.prompt_char_budget = prompt_char_budget

        self.facts: Dict[int, Fact] = {}
        self.index = BM25FIndex()
        self.graph = EntityGraph()
        self.entity_facts: Dict[str, Set[int]] = defaultdict(set)
        self.key_owner: Dict[Tuple[str, str], int] = {}
        self._next_id = 1
        self._lock = threading.RLock()

        # cold-path consolidator (same shape as DPHM's)
        self._tasks: "queue.Queue[Optional[tuple]]" = queue.Queue()
        self._worker = threading.Thread(target=self._consolidator, daemon=True)
        self._worker.start()

        # speculative prefetch: latest-request-wins mailbox + snapshot slot
        self.prefetch_debounce_s = prefetch_debounce_s
        self._prefetch_req: List[tuple] = []
        self._prefetch_cv = threading.Condition()
        self._snapshot: RetrievalSnapshot = EMPTY_SNAPSHOT
        self._prefetcher = threading.Thread(target=self._prefetch_loop, daemon=True)
        self._prefetcher.start()

    # ------------------------------------------------------------------
    # Write path (cold)
    # ------------------------------------------------------------------
    def observe_document(self, source_id: str, text: str,
                         participants: Sequence[str] = (),
                         now: Optional[float] = None) -> None:
        """Async: enqueue and return immediately (call from the app's save/
        send hook)."""
        self._tasks.put(("doc", source_id, text, tuple(participants),
                         time.time() if now is None else now))

    def ingest_document(self, source_id: str, text: str,
                        participants: Sequence[str] = (),
                        now: Optional[float] = None) -> List[Fact]:
        """Sync variant (tests / bulk import)."""
        return self._ingest(source_id, text, tuple(participants),
                            time.time() if now is None else now)

    def add_fact(self, draft: FactDraft, source_id: str = "manual",
                 participants: Sequence[str] = (),
                 now: Optional[float] = None) -> Optional[Fact]:
        """Direct insertion, e.g. from an LLM extractor or a UI."""
        now = time.time() if now is None else now
        with self._lock:
            return self._admit(draft, source_id, tuple(participants), now)

    def _consolidator(self) -> None:
        while True:
            task = self._tasks.get()
            if task is None:
                return
            kind = task[0]
            try:
                if kind == "doc":
                    _, source_id, text, participants, now = task
                    self._ingest(source_id, text, participants, now)
                elif kind == "prune":
                    self._prune(task[1])
            except Exception:
                pass  # cold path must never take down the host app
            finally:
                self._tasks.task_done()

    def _ingest(self, source_id: str, text: str,
                participants: Tuple[str, ...], now: float) -> List[Fact]:
        drafts = self.extractor(text)
        admitted: List[Fact] = []
        with self._lock:
            for d in drafts:
                f = self._admit(d, source_id, participants, now)
                if f is not None:
                    admitted.append(f)
        return admitted

    def _admit(self, d: FactDraft, source_id: str,
               participants: Tuple[str, ...], now: float) -> Optional[Fact]:
        """Mem0-style update stage decided by rules:
        near-duplicate -> NOOP + reinforce;  same key -> supersede;  else ADD."""
        # (a) dedup against facts sharing an entity (small candidate set)
        new_toks = set(index_terms(d.text))
        cands: Set[int] = set()
        for e in d.entities:
            cands |= self.entity_facts.get(e, set())
        for fid in cands:
            old = self.facts[fid]
            if not old.valid:
                continue
            old_toks = set(index_terms(old.text))
            union = len(new_toks | old_toks)
            if union and len(new_toks & old_toks) / union >= self.dedup_jaccard:
                # re-observation == consolidation signal (Ebbinghaus, as in DPHM)
                old.heat.bump(self.heat_log_gamma, now)
                old.last_reinforced = now
                return None
        # (b) slot supersede (bi-temporal, Zep-style)
        if d.key is not None and d.key in self.key_owner:
            prev = self.facts.get(self.key_owner[d.key])
            if prev is not None and prev.valid:
                prev.invalid_at = now
                self.index.remove(prev)   # invalid facts are not retrievable
        # (c) add
        fact = Fact(
            fact_id=self._next_id, text=d.text, entities=d.entities,
            participants=participants, source_id=source_id, kind=d.kind,
            key=d.key, created_at=now, valid_from=now, last_reinforced=now,
        )
        self._next_id += 1
        self.facts[fact.fact_id] = fact
        self.index.add(fact)
        for e in fact.entities:
            self.entity_facts[e].add(fact.fact_id)
        if fact.key is not None:
            self.key_owner[fact.key] = fact.fact_id
        self.graph.observe(fact.entities + tuple(p.lower() for p in participants), now)
        return fact

    # ------------------------------------------------------------------
    # Forgetting (cold)
    # ------------------------------------------------------------------
    def request_prune(self, min_score: float = 0.02) -> None:
        self._tasks.put(("prune", min_score))

    def _prune(self, min_score: float) -> None:
        now = time.time()
        with self._lock:
            doomed = []
            for f in self.facts.values():
                if f.kind == "profile":
                    continue  # profile facts are pinned (Letta core-memory tier)
                rec = math.exp(self.recency_log_gamma * (now - f.last_reinforced))
                keep = rec * (1.0 + f.heat.read(self.heat_log_gamma, now))
                if not f.valid or keep < min_score:
                    doomed.append(f)
            for f in doomed:
                self.index.remove(f)
                self.facts.pop(f.fact_id, None)
                for e in f.entities:
                    self.entity_facts[e].discard(f.fact_id)
                    if not self.entity_facts[e]:
                        del self.entity_facts[e]
                if f.key is not None and self.key_owner.get(f.key) == f.fact_id:
                    del self.key_owner[f.key]
            self.graph.prune(now)

    # ------------------------------------------------------------------
    # Read path
    # ------------------------------------------------------------------
    def _build_query(self, context: str,
                     participants: Sequence[str]) -> Dict[Token, float]:
        """Focus terms: positional recency weighting (terms nearer the
        cursor matter more), stopword removal, then IDF-aware pruning to
        `max_query_terms` (WAND-spirit budget on posting-list work)."""
        toks = index_terms(context)
        weights: Dict[Token, float] = defaultdict(float)
        n = len(toks)
        for i, t in enumerate(toks):
            if t in _STOPWORDS or (len(t) == 1 and not _CJK_RE.fullmatch(t)):
                continue
            weights[t] += self.query_pos_decay ** (n - 1 - i)
        for p in participants:
            for t in index_terms(p):
                if t not in _STOPWORDS:
                    weights[t] += 1.5  # audience terms are strong signals
        if len(weights) > self.max_query_terms:
            ranked = heapq.nlargest(
                self.max_query_terms, weights.items(),
                key=lambda kv: kv[1] * max(self.index.idf(kv[0]), 1e-6))
            weights = dict(ranked)
        return weights

    def retrieve(self, context: str, participants: Sequence[str] = (),
                 k: int = 6, now: Optional[float] = None) -> RetrievalSnapshot:
        """Synchronous scoring:
        score(f) = BM25F(q,f) * (eps + (1-eps)*recency(f)) * (1 + eta*heat(f))
                   + gamma * assoc(f)
        with invalid facts excluded and optional RRF fusion of `semantic_fn`.
        """
        t0 = time.perf_counter()
        now = time.time() if now is None else now
        with self._lock:
            query = self._build_query(context, participants)
            lex = self.index.score_all(query)

            # associative recall: seeds = context entities + participants
            seeds = [t for t in query if t in self.entity_facts]
            seeds += [p.lower() for p in participants if p.lower() in self.entity_facts]
            assoc: Dict[int, float] = defaultdict(float)
            if seeds:
                act = self.graph.expand(seeds, now)
                for ent, a in act.items():
                    for fid in self.entity_facts.get(ent, ()):
                        assoc[fid] += a

            scored: Dict[int, float] = {}
            for fid in set(lex) | set(assoc):
                f = self.facts.get(fid)
                if f is None or not f.valid:
                    continue
                rec = self.recency_floor + (1.0 - self.recency_floor) * math.exp(
                    self.recency_log_gamma * (now - f.last_reinforced))
                heat = f.heat.read(self.heat_log_gamma, now)
                s = lex.get(fid, 0.0) * rec * (1.0 + self.heat_eta * heat)
                s += self.assoc_gamma * assoc.get(fid, 0.0)
                if s > 0.0:
                    scored[fid] = s

            top = heapq.nlargest(k * 2 if self.semantic_fn else k,
                                 scored.items(), key=lambda kv: kv[1])
            ranked = [self.facts[fid] for fid, _ in top]

        if self.semantic_fn is not None:
            ranked = self._rrf_fuse(ranked, context, k)
        ranked = ranked[:k]

        latency = (time.perf_counter() - t0) * 1000.0
        return RetrievalSnapshot(
            facts=tuple(ranked),
            prompt_block=self._format_prompt(ranked),
            query_terms=tuple(query),
            created_at=now, latency_ms=latency,
        )

    def _rrf_fuse(self, lexical: List[Fact], context: str, k: int,
                  rrf_k: int = 60) -> List[Fact]:
        """Reciprocal Rank Fusion (as used by Zep/Graphiti) between the
        lexical ranking and the optional semantic backup. `semantic_fn`
        returns [(fact_text, score)]; texts are matched back to facts."""
        by_text = {f.text: f for f in self.facts.values() if f.valid}
        rrf: Dict[int, float] = defaultdict(float)
        for r, f in enumerate(lexical):
            rrf[f.fact_id] += 1.0 / (rrf_k + r)
        try:
            sem = self.semantic_fn(context, k)
        except Exception:
            sem = []
        for r, (text, _) in enumerate(sem):
            f = by_text.get(text)
            if f is not None:
                rrf[f.fact_id] += 1.0 / (rrf_k + r)
        order = heapq.nlargest(k, rrf.items(), key=lambda kv: kv[1])
        return [self.facts[fid] for fid, _ in order if fid in self.facts]

    def _format_prompt(self, facts: Sequence[Fact]) -> str:
        if not facts:
            return ""
        lines, used = ["[Relevant memory]"], 0
        for f in facts:
            when = time.strftime("%Y-%m-%d", time.localtime(f.created_at))
            who = f", to {', '.join(f.participants)}" if f.participants else ""
            line = f"- ({when}{who}) {f.text}"
            if used + len(line) > self.prompt_char_budget:
                break
            lines.append(line)
            used += len(line)
        return "\n".join(lines) if len(lines) > 1 else ""

    # ------------------------------------------------------------------
    # Parallelism with text_fill
    # ------------------------------------------------------------------
    def poke_prefetch(self, context: str, participants: Sequence[str] = (),
                      k: int = 6) -> None:
        """Call on word boundaries / pauses. Debounced, latest-wins;
        never blocks the caller."""
        with self._prefetch_cv:
            self._prefetch_req[:] = [(context, tuple(participants), k, time.time())]
            self._prefetch_cv.notify()

    def snapshot(self) -> RetrievalSnapshot:
        """One attribute read; safe from any thread, any keystroke."""
        return self._snapshot

    def _prefetch_loop(self) -> None:
        while True:
            with self._prefetch_cv:
                while not self._prefetch_req:
                    self._prefetch_cv.wait()
                context, participants, k, stamp = self._prefetch_req.pop()
            # debounce: absorb the burst, keep only the newest request
            remaining = self.prefetch_debounce_s - (time.time() - stamp)
            if remaining > 0:
                time.sleep(remaining)
                with self._prefetch_cv:
                    if self._prefetch_req:
                        continue
            try:
                self._snapshot = self.retrieve(context, participants, k)
            except Exception:
                pass

    def retrieve_with_deadline(self, context: str,
                               participants: Sequence[str] = (),
                               k: int = 6,
                               deadline_s: float = 0.02) -> RetrievalSnapshot:
        """Race a fresh retrieval against `deadline_s` (fire this in
        parallel with the text_fill request's prefill). On miss, return
        the latest prefetch snapshot marked stale -- never block."""
        box: List[RetrievalSnapshot] = []
        done = threading.Event()

        def work() -> None:
            try:
                box.append(self.retrieve(context, participants, k))
            finally:
                done.set()

        threading.Thread(target=work, daemon=True).start()
        if done.wait(deadline_s) and box:
            return box[0]
        snap = self._snapshot
        return RetrievalSnapshot(snap.facts, snap.prompt_block, snap.query_terms,
                                 snap.created_at, snap.latency_ms, stale=True)

    # ------------------------------------------------------------------
    # Feedback (closes the consolidation loop)
    # ------------------------------------------------------------------
    def mark_used(self, fact_ids: Iterable[int], now: Optional[float] = None) -> None:
        """Call when the user *accepts* a completion whose prompt included
        these facts: retrieval-that-helped is the consolidation signal."""
        now = time.time() if now is None else now
        with self._lock:
            for fid in fact_ids:
                f = self.facts.get(fid)
                if f is not None:
                    f.heat.bump(self.heat_log_gamma, now)
                    f.last_reinforced = now

    # ------------------------------------------------------------------
    def flush(self, timeout: float = 5.0) -> None:
        """Wait for the cold path to drain (tests)."""
        deadline = time.time() + timeout
        while not self._tasks.empty() and time.time() < deadline:
            time.sleep(0.005)
        self._tasks.join()

    def stats(self) -> Dict[str, int]:
        with self._lock:
            return {
                "facts": len(self.facts),
                "valid_facts": sum(f.valid for f in self.facts.values()),
                "index_terms": len(self.index.postings),
                "entities": len(self.entity_facts),
                "graph_nodes": len(self.graph.adj),
            }
