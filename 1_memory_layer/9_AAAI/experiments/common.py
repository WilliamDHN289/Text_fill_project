"""Shared infrastructure for the AAAI-27 experiments.

- Loads config.yaml (the single source of parameters for every study).
- Builds a ConfigurableDPFM: the reference implementation in ../../5_dpfm/dpfm.py
  with every parameter (including the ones hard-coded there) exposed to YAML.
- Candidate retrieval with per-fact feature breakdown (Study 3 needs
  the raw BM25F / recency / heat / assoc components, not just the fused score).
"""

from __future__ import annotations

import heapq
import json
import math
import platform
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import yaml

EXP_DIR = Path(__file__).resolve().parent
DPFM_DIR = EXP_DIR.parent.parent / "5_dpfm"
sys.path.insert(0, str(DPFM_DIR))

import dpfm  # noqa: E402  (reference implementation, stdlib-only)

import corpus as corpus_mod  # noqa: E402

DAY = corpus_mod.DAY
BASE = corpus_mod.BASE


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def load_config(path: Path | None = None) -> dict:
    with open(path or EXP_DIR / "config.yaml", "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def env_info() -> dict:
    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "machine": platform.machine(),
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


# --------------------------------------------------------------------------
# ConfigurableDPFM: expose the parameters dpfm.py hard-codes
# --------------------------------------------------------------------------

class ConfigurableDPFM(dpfm.DualPathFactMemory):
    """DualPathFactMemory with every knob driven by the YAML config.

    dpfm.py hard-codes three things we need to vary: BM25F field weights
    (class attribute), the participant query boost (1.5 in _build_query),
    and the graph expansion defaults (damping/top in retrieve's call).
    We shadow the first with an instance attribute, override _build_query
    for the second, and wrap graph.expand for the third.
    """

    def __init__(self, dcfg: dict, extractor=None):
        r, s, g = dcfg["retrieval"], dcfg["scoring"], dcfg["graph"]
        super().__init__(
            extractor=extractor
            or dpfm.make_rule_extractor(gazetteer=dcfg["extraction"]["gazetteer"]),
            recency_half_life_s=s["recency_half_life_days"] * DAY,
            heat_half_life_s=s["heat_half_life_days"] * DAY,
            recency_floor=s["recency_floor"],
            heat_eta=s["heat_eta"],
            assoc_gamma=s["assoc_gamma"],
            max_query_terms=r["max_query_terms"],
            query_pos_decay=r["query_pos_decay"],
            dedup_jaccard=dcfg["admission"]["dedup_jaccard"],
            prompt_char_budget=r["prompt_char_budget"],
        )
        self.k_default = r["k"]
        self.participant_boost = r["participant_boost"]
        # instance attribute shadows the class-level FIELD_WEIGHTS
        self.index.FIELD_WEIGHTS = {
            "text": s["field_weight_text"],
            "entities": s["field_weight_entities"],
            "participants": s["field_weight_participants"],
        }
        self.graph.max_degree = g["max_degree"]
        _orig_expand = self.graph.expand
        damping, top = g["damping"], g["expand_top"]
        self.graph.expand = (
            lambda seeds, now, d=damping, t=top: _orig_expand(seeds, now, d, t))

    def _build_query(self, context: str,
                     participants: Sequence[str]) -> Dict[str, float]:
        """Copy of dpfm.DualPathFactMemory._build_query with the participant
        boost read from config instead of the literal 1.5."""
        toks = dpfm.index_terms(context)
        weights: Dict[str, float] = defaultdict(float)
        n = len(toks)
        for i, t in enumerate(toks):
            if t in dpfm._STOPWORDS or (len(t) == 1 and not dpfm._CJK_RE.fullmatch(t)):
                continue
            weights[t] += self.query_pos_decay ** (n - 1 - i)
        for p in participants:
            for t in dpfm.index_terms(p):
                if t not in dpfm._STOPWORDS:
                    weights[t] += self.participant_boost
        if len(weights) > self.max_query_terms:
            ranked = heapq.nlargest(
                self.max_query_terms, weights.items(),
                key=lambda kv: kv[1] * max(self.index.idf(kv[0]), 1e-6))
            weights = dict(ranked)
        return weights


def build_memory(dcfg: dict, messages, extractor=None,
                 cls=None) -> ConfigurableDPFM:
    """Ingest (daysAgo, partner, text) messages through the real data flow."""
    mem = (cls or ConfigurableDPFM)(dcfg, extractor=extractor)
    for days_ago, partner, text in messages:
        mem.ingest_document("replay", text, participants=[partner],
                            now=BASE - days_ago * DAY)
    return mem


class TemporalDPFM(ConfigurableDPFM):
    """ConfigurableDPFM with the keyed-supersession fix (paper: 'keyed
    revision works end to end').

    Upstream _admit runs Jaccard dedup BEFORE the key check, so a revision
    that reuses the sentence template with only the value changed
    (Jaccard >= 0.8) is swallowed as a re-observation and the slot never
    updates. Here, when a draft carries a key: an *identical* sentence
    reinforces the current owner (true re-observation); anything else with
    the same key supersedes it bitemporally. Keyless drafts fall through to
    the stock path.
    """

    def _admit(self, d, source_id, participants, now):
        if d.key is None:
            return super()._admit(d, source_id, participants, now)
        owner_id = self.key_owner.get(d.key)
        if owner_id is not None:
            prev = self.facts.get(owner_id)
            if prev is not None and prev.valid:
                if prev.text.strip().lower() == d.text.strip().lower():
                    prev.heat.bump(self.heat_log_gamma, now)
                    prev.last_reinforced = now
                    return None
                prev.invalid_at = now
                self.index.remove(prev)
        fact = dpfm.Fact(
            fact_id=self._next_id, text=d.text, entities=d.entities,
            participants=tuple(participants), source_id=source_id,
            kind=d.kind, key=d.key, created_at=now, valid_from=now,
            last_reinforced=now,
        )
        self._next_id += 1
        self.facts[fact.fact_id] = fact
        self.index.add(fact)
        for e in fact.entities:
            self.entity_facts[e].add(fact.fact_id)
        self.key_owner[fact.key] = fact.fact_id
        self.graph.observe(
            fact.entities + tuple(p.lower() for p in participants), now)
        return fact


# --------------------------------------------------------------------------
# Candidate retrieval with feature breakdown (Study 3 / Study 4)
# --------------------------------------------------------------------------

def retrieve_candidates(mem: ConfigurableDPFM, context: str,
                        participants: Sequence[str], now: float,
                        shortlist: int) -> List[dict]:
    """Replicates the scoring pipeline of DualPathFactMemory.retrieve but
    returns per-fact feature components:
      bm25   raw BM25F score
      rec    exp recency decay in (0, 1] (before the epsilon floor)
      heat   decayed usage counter
      assoc  entity-graph activation mass
      score  the deployed fusion score (Eq. 1 of the paper)
    """
    with mem._lock:
        query = mem._build_query(context, participants)
        lex = mem.index.score_all(query)

        seeds = [t for t in query if t in mem.entity_facts]
        seeds += [p.lower() for p in participants if p.lower() in mem.entity_facts]
        assoc: Dict[int, float] = defaultdict(float)
        if seeds:
            act = mem.graph.expand(seeds, now)
            for ent, a in act.items():
                for fid in mem.entity_facts.get(ent, ()):
                    assoc[fid] += a

        out: List[dict] = []
        for fid in set(lex) | set(assoc):
            f = mem.facts.get(fid)
            if f is None or not f.valid:
                continue
            rec = math.exp(mem.recency_log_gamma * (now - f.last_reinforced))
            heat = f.heat.read(mem.heat_log_gamma, now)
            score = (lex.get(fid, 0.0)
                     * (mem.recency_floor + (1.0 - mem.recency_floor) * rec)
                     * (1.0 + mem.heat_eta * heat)
                     + mem.assoc_gamma * assoc.get(fid, 0.0))
            out.append({
                "fact_id": fid,
                "text": f.text,
                "entities": f.entities,
                "len": len(f.text),
                "bm25": lex.get(fid, 0.0),
                "rec": rec,
                "heat": heat,
                "assoc": assoc.get(fid, 0.0),
                "score": score,
            })
        out.sort(key=lambda c: -c["score"])
        return out[:shortlist]


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def percentile(sorted_vals: List[float], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    idx = min(len(sorted_vals) - 1, int(round(p / 100.0 * (len(sorted_vals) - 1))))
    return sorted_vals[idx]


def latency_summary(vals_ms: List[float]) -> dict:
    v = sorted(vals_ms)
    return {
        "n": len(v),
        "p50_ms": round(percentile(v, 50), 4),
        "p95_ms": round(percentile(v, 95), 4),
        "max_ms": round(v[-1], 4) if v else float("nan"),
    }


def write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
