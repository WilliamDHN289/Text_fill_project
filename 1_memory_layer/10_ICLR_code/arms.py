"""Retrieval arms. Every arm ranks facts from the same store and goes through
the same `pfm.select` and `pfm.format_block`, so arms differ only in ranking.

  pfm                  PFM ranker (active facts only)
  bm25                 text BM25 over all retained facts
  bm25_recency         bm25 x PFM's recency factor
  bm25_validity        bm25 over the active facts PFM serves
  dense, dense_validity    MiniLM cosine over all / active facts
  hybrid, hybrid_validity  RRF(60) of the bm25 and dense shortlists
  +P  (suffix)         the arm also receives P_t: participant names are
                       appended to the query and to each fact's text
  participant_filter   wrapper: drop facts whose participants miss P_t
  cutoff@tau           wrapper: drop facts scoring below tau x top score
"""

from __future__ import annotations

import heapq
import math
import os
import time
from collections import defaultdict
from typing import Dict, List, Sequence, Tuple

import pfm

Ranked = List[Tuple[pfm.Fact, float]]
RRF_K = 60


def _terms(text: str) -> List[str]:
    return [t for t in pfm.tokenize(text) if t not in pfm.STOPWORDS and len(t) > 1]


def _doc(f: pfm.Fact, participants: bool) -> str:
    return f"{f.text} {' '.join(f.participants)}" if participants else f.text


class Arm:
    name = "arm"

    def rank(self, prefix: str, partners: Sequence[str], now: float) -> Ranked:
        raise NotImplementedError


class PFMArm(Arm):
    name = "pfm"

    def __init__(self, store: pfm.PFM, name: str = "pfm"):
        self.store, self.name = store, name

    def rank(self, prefix, partners, now):
        return self.store.rank(prefix, partners, now)


class BM25Arm(Arm):
    """Plain text BM25; optional validity filter, recency factor, and P_t."""

    def __init__(self, store: pfm.PFM, valid_only=False, recency=False, participants=False,
                 k1=1.2, b=0.75, shortlist=50):
        self.name = ("bm25_validity" if valid_only else "bm25_recency" if recency else "bm25") \
            + ("+P" if participants else "")
        self.participants, self.shortlist, self.k1, self.b = participants, shortlist, k1, b
        self.facts = [f for f in store.facts.values() if f.active or not valid_only]
        self.postings: Dict[str, Dict[int, int]] = defaultdict(dict)
        self.dl: Dict[int, int] = {}
        for i, f in enumerate(self.facts):
            toks = pfm.tokenize(_doc(f, participants))
            self.dl[i] = len(toks)
            for t in toks:
                self.postings[t][i] = self.postings[t].get(i, 0) + 1
        self.avgdl = sum(self.dl.values()) / max(1, len(self.dl))
        s = store.cfg["scoring"]
        self.recency = recency
        self.eps, self.log_gamma = s["recency_floor"], store.rec_log_gamma

    def rank(self, prefix, partners, now):
        query = prefix + (" " + " ".join(partners) if self.participants else "")
        acc: Dict[int, float] = defaultdict(float)
        n = len(self.dl)
        for t in set(_terms(query)):
            plist = self.postings.get(t, {})
            idf = math.log(1 + (n - len(plist) + 0.5) / (len(plist) + 0.5))
            for i, tf in plist.items():
                norm = self.k1 * (1 - self.b + self.b * self.dl[i] / self.avgdl)
                acc[i] += idf * tf * (self.k1 + 1) / (tf + norm)
        if self.recency:
            for i in acc:
                age = now - self.facts[i].last_seen
                acc[i] *= self.eps + (1 - self.eps) * math.exp(self.log_gamma * age)
        top = heapq.nlargest(self.shortlist, acc.items(), key=lambda kv: (kv[1], -kv[0]))
        return [(self.facts[i], s) for i, s in top]


class Encoder:
    """all-MiniLM-L6-v2 on CPU, batch size 1 at query time."""

    def __init__(self, cfg: dict):
        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
        import torch
        from sentence_transformers import SentenceTransformer
        torch.set_num_threads(cfg["torch_threads"])
        self.model = SentenceTransformer(cfg["model"], device=cfg["device"])
        self.info = {"model": cfg["model"], "device": cfg["device"],
                     "torch_threads": torch.get_num_threads(), "query_batch": 1,
                     "torch": torch.__version__, "embedding_cache": "corpus only"}
        self.encode(["warmup"] * 4)

    def encode(self, texts: Sequence[str]):
        import numpy as np
        return np.asarray(self.model.encode(list(texts), batch_size=64,
                                            normalize_embeddings=True,
                                            show_progress_bar=False), dtype=np.float32)


class DenseArm(Arm):
    def __init__(self, store: pfm.PFM, encoder: Encoder, valid_only=False, participants=False,
                 shortlist=50):
        self.name = ("dense_validity" if valid_only else "dense") + ("+P" if participants else "")
        self.encoder, self.participants, self.shortlist = encoder, participants, shortlist
        self.facts = [f for f in store.facts.values() if f.active or not valid_only]
        t0 = time.perf_counter()
        self.matrix = encoder.encode([_doc(f, participants) for f in self.facts])
        self.build_s = time.perf_counter() - t0
        self.last_encode_ms = 0.0

    def rank(self, prefix, partners, now):
        import numpy as np
        query = (" ".join(partners) + ": " if self.participants else "") + prefix
        t0 = time.perf_counter()
        qv = self.encoder.encode([query])[0]
        self.last_encode_ms = (time.perf_counter() - t0) * 1e3
        sims = self.matrix @ qv
        k = min(self.shortlist, len(sims))
        idx = np.argpartition(-sims, k - 1)[:k]
        idx = idx[np.argsort(-sims[idx], kind="stable")]
        return [(self.facts[i], float(sims[i])) for i in idx]


class HybridArm(Arm):
    def __init__(self, lexical: BM25Arm, dense: DenseArm):
        self.lexical, self.dense = lexical, dense
        self.name = dense.name.replace("dense", "hybrid")

    def rank(self, prefix, partners, now):
        fused: Dict[int, float] = defaultdict(float)
        by_id = {}
        for ranked in (self.lexical.rank(prefix, partners, now),
                       self.dense.rank(prefix, partners, now)):
            for r, (f, _) in enumerate(ranked):
                fused[f.fact_id] += 1 / (RRF_K + r + 1)
                by_id[f.fact_id] = f
        top = heapq.nlargest(50, fused.items(), key=lambda kv: (kv[1], -kv[0]))
        return [(by_id[i], s) for i, s in top]


class ParticipantFilter(Arm):
    def __init__(self, inner: Arm):
        self.inner, self.name = inner, f"{inner.name}|participant_filter"

    def rank(self, prefix, partners, now):
        want = set(partners)
        return [(f, s) for f, s in self.inner.rank(prefix, partners, now)
                if want & set(f.participants)]


class RelativeCutoff(Arm):
    def __init__(self, inner: Arm, tau: float):
        self.inner, self.tau, self.name = inner, tau, f"{inner.name}|cutoff@{tau}"

    def rank(self, prefix, partners, now):
        ranked = self.inner.rank(prefix, partners, now)
        return [(f, s) for f, s in ranked if ranked and s >= self.tau * ranked[0][1]]


def serve(arm: Arm, prefix: str, partners: Sequence[str], now: float, k: int, budget: int):
    """One request: rank, select, format. Returns (block, ranked, latency_ms)."""
    t0 = time.perf_counter()
    ranked = arm.rank(prefix, partners, now)
    block = pfm.format_block(pfm.select([f for f, _ in ranked], k, budget))
    return block, ranked, (time.perf_counter() - t0) * 1e3
