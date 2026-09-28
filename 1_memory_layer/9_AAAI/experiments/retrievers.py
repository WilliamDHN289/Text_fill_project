"""Retrieval baseline arms on a shared corpus / device / budget (task 2).

All arms rank the *same* extracted facts and emit a prompt block through
the same formatter and character budget. Temporal information (bitemporal
validity bits) is given only to arms whose name says so.

  pfm_full        the deployed retriever (fields + recency + heat + assoc,
                  invalid facts excluded)  — wraps mem.retrieve
  pfm_snapshot    same result set, served from a prefetched snapshot
                  (O(1) read; latency ~0 by construction)
  bm25_plain      text-only BM25 over ALL facts (no temporal handling)
  bm25_recency    bm25_plain x the same recency decay PFM uses
  temporal_bm25   bm25_plain restricted to currently valid facts
                  (same update information as PFM, no field weighting)
  dense           small local dense retriever (MiniLM if available,
                  otherwise a hashed n-gram proxy, honestly labeled)
  hybrid_rrf      RRF(60) fusion of bm25_plain and dense

Latency boundary (uniform for every arm): wall time around
`arm.retrieve(...)`, which includes query construction / encoding, scoring,
ranking, and top-k selection; block formatting is measured inside the same
call for parity with the deployed path.
"""

from __future__ import annotations

import heapq
import math
import time
from collections import defaultdict
from typing import Dict, List, Tuple

import common
import dpfm

RRF_K = 60


def format_block(facts, budget: int) -> str:
    if not facts:
        return ""
    lines, used = ["[Relevant memory]"], 0
    for f in facts:
        who = f", to {', '.join(f.participants)}" if f.participants else ""
        line = f"- (day {int((f.created_at - common.BASE) / common.DAY)}{who}) {f.text}"
        if used + len(line) > budget:
            break
        lines.append(line)
        used += len(line)
    return "\n".join(lines) if len(lines) > 1 else ""


def _query_tokens(context: str) -> Dict[str, float]:
    """Plain uniform-weight query: stopword-filtered index terms."""
    out: Dict[str, float] = {}
    for t in dpfm.index_terms(context):
        if t in dpfm._STOPWORDS or (len(t) == 1 and not dpfm._CJK_RE.fullmatch(t)):
            continue
        out[t] = 1.0
    return out


class _TextBM25:
    """Text-only BM25 over an explicit fact list (validity-agnostic)."""

    def __init__(self, facts, k1=1.2, b=0.75):
        self.k1, self.b = k1, b
        self.facts = list(facts)
        self.postings: Dict[str, Dict[int, int]] = defaultdict(dict)
        self.doc_len: Dict[int, int] = {}
        for f in self.facts:
            toks = dpfm.index_terms(f.text)
            self.doc_len[f.fact_id] = len(toks)
            for t in toks:
                self.postings[t][f.fact_id] = self.postings[t].get(f.fact_id, 0) + 1
        self.by_id = {f.fact_id: f for f in self.facts}
        self.avgdl = (sum(self.doc_len.values()) / len(self.doc_len)
                      if self.doc_len else 1.0)

    def score(self, query: Dict[str, float]) -> Dict[int, float]:
        n = len(self.doc_len)
        acc: Dict[int, float] = defaultdict(float)
        for term, qw in query.items():
            plist = self.postings.get(term)
            if not plist:
                continue
            idf = math.log(1.0 + (n - len(plist) + 0.5) / (len(plist) + 0.5))
            for fid, tf in plist.items():
                norm = self.k1 * (1 - self.b + self.b * self.doc_len[fid] / self.avgdl)
                acc[fid] += qw * idf * tf * (self.k1 + 1) / (tf + norm)
        return acc


class Arm:
    name = "base"
    uses_temporal = False

    def prepare(self, mem, cfg):                       # noqa: D401
        raise NotImplementedError

    def retrieve(self, prefix, partner, k, budget, now):
        raise NotImplementedError


class PfmFull(Arm):
    name = "pfm_full"
    uses_temporal = True

    def prepare(self, mem, cfg):
        self.mem = mem

    def retrieve(self, prefix, partner, k, budget, now):
        old = self.mem.prompt_char_budget
        self.mem.prompt_char_budget = budget
        snap = self.mem.retrieve(prefix, participants=[partner], k=k, now=now)
        self.mem.prompt_char_budget = old
        return snap.prompt_block, list(snap.facts)


class PfmSnapshot(PfmFull):
    """Same ranking; models the deployed snapshot read (zero hot-path cost).
    The driver assigns it latency 0 and reuses pfm_full's block."""
    name = "pfm_snapshot"


class Bm25Plain(Arm):
    name = "bm25_plain"

    def _facts(self, mem):
        return list(mem.facts.values())                # ALL facts, no validity

    def prepare(self, mem, cfg):
        self.idx = _TextBM25(self._facts(mem))

    def _rank(self, prefix, k):
        acc = self.idx.score(_query_tokens(prefix))
        top = heapq.nlargest(k, acc.items(), key=lambda kv: kv[1])
        return [self.idx.by_id[fid] for fid, _ in top]

    def retrieve(self, prefix, partner, k, budget, now):
        facts = self._rank(prefix, k)
        return format_block(facts, budget), facts


class Bm25Recency(Bm25Plain):
    name = "bm25_recency"

    def prepare(self, mem, cfg):
        super().prepare(mem, cfg)
        s = cfg["dpfm"]["scoring"]
        self.floor = s["recency_floor"]
        self.log_gamma = -math.log(2.0) / (s["recency_half_life_days"] * common.DAY)

    def retrieve(self, prefix, partner, k, budget, now):
        acc = self.idx.score(_query_tokens(prefix))
        scored = []
        for fid, sc in acc.items():
            f = self.idx.by_id[fid]
            rec = self.floor + (1 - self.floor) * math.exp(
                self.log_gamma * (now - f.last_reinforced))
            scored.append((fid, sc * rec))
        top = heapq.nlargest(k, scored, key=lambda kv: kv[1])
        facts = [self.idx.by_id[fid] for fid, _ in top]
        return format_block(facts, budget), facts


class TemporalBm25(Bm25Plain):
    name = "temporal_bm25"
    uses_temporal = True

    def _facts(self, mem):
        return [f for f in mem.facts.values() if f.valid]


class Dense(Arm):
    """Small local dense retriever. Real MiniLM when importable; otherwise a
    hashed char-3gram/word random-projection proxy (flagged in `backend`)."""
    name = "dense"

    def prepare(self, mem, cfg):
        import numpy as np
        self.np = np
        self.facts = list(mem.facts.values())
        texts = [f.text for f in self.facts]
        model_name = cfg["study6"]["dense_model"]
        try:
            import os
            os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
            from sentence_transformers import SentenceTransformer
            self.model = SentenceTransformer(model_name)
            self.backend = model_name
            M = self.model.encode(texts, batch_size=64,
                                  normalize_embeddings=True,
                                  show_progress_bar=False)
            self.model.encode(["warmup query"], normalize_embeddings=True)
        except Exception as e:                          # offline / not installed
            self.model = None
            self.backend = f"hashed-ngram-proxy ({type(e).__name__})"
            M = self._hash_encode(texts)
        self.M = np.asarray(M, dtype=np.float32)

    def _hash_encode(self, texts, dim=384):
        np = self.np
        out = np.zeros((len(texts), dim), dtype=np.float32)
        for i, t in enumerate(texts):
            low = t.lower()
            grams = [low[j:j + 3] for j in range(len(low) - 2)] + low.split()
            for g in grams:
                out[i, hash(g) % dim] += 1.0
        n = np.linalg.norm(out, axis=1, keepdims=True)
        return out / np.maximum(n, 1e-9)

    def _encode_query(self, prefix):
        if self.model is not None:
            return self.model.encode([prefix], normalize_embeddings=True)[0]
        return self._hash_encode([prefix])[0]

    def retrieve(self, prefix, partner, k, budget, now):
        q = self.np.asarray(self._encode_query(prefix), dtype=self.np.float32)
        sims = self.M @ q
        idx = self.np.argpartition(-sims, min(k, len(sims) - 1))[:k]
        idx = idx[self.np.argsort(-sims[idx])]
        facts = [self.facts[i] for i in idx]
        return format_block(facts, budget), facts


class HybridRRF(Arm):
    name = "hybrid_rrf"

    def prepare(self, mem, cfg):
        self.bm25 = Bm25Plain()
        self.bm25.prepare(mem, cfg)
        self.dense = Dense()
        self.dense.prepare(mem, cfg)
        self.backend = self.dense.backend

    def retrieve(self, prefix, partner, k, budget, now):
        lex = self.bm25._rank(prefix, 40)
        _, den = self.dense.retrieve(prefix, partner, 40, 10 ** 9, now)
        rrf: Dict[int, float] = defaultdict(float)
        by_id = {}
        for r, f in enumerate(lex):
            rrf[f.fact_id] += 1.0 / (RRF_K + r)
            by_id[f.fact_id] = f
        for r, f in enumerate(den):
            rrf[f.fact_id] += 1.0 / (RRF_K + r)
            by_id[f.fact_id] = f
        top = heapq.nlargest(k, rrf.items(), key=lambda kv: kv[1])
        facts = [by_id[fid] for fid, _ in top]
        return format_block(facts, budget), facts


ARM_CLASSES = {c.name: c for c in
               [PfmFull, PfmSnapshot, Bm25Plain, Bm25Recency, TemporalBm25,
                Dense, HybridRRF]}


def build_arms(names, mem, cfg) -> Tuple[List[Arm], Dict[str, float]]:
    arms, build_s = [], {}
    for n in names:
        arm = ARM_CLASSES[n]()
        t0 = time.perf_counter()
        arm.prepare(mem, cfg)
        build_s[n] = round(time.perf_counter() - t0, 3)
        arms.append(arm)
    return arms, build_s
