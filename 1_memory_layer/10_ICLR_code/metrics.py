"""Per-query outcomes, slices, and paired statistics.

Every experiment writes one JSON row per (condition, query); every table is
derived from those rows, so new columns or slices never require a re-run.
"""

from __future__ import annotations

import json
import math
import random
from collections import defaultdict
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence

import benchmark as B

METRICS = ("current", "stale", "wrong", "coinject", "clean", "abstain")

SLICES: Dict[str, Callable[[dict], bool]] = {
    "all": lambda m: True,
    "ambiguous": lambda m: m["ambiguous"],
    "unambiguous": lambda m: not m["ambiguous"],
    "revised": lambda m: m["revisions"] >= 1,
    "unrevised": lambda m: m["revisions"] == 0,
    "cancelled": lambda m: m["cancel"],
    "verbatim": lambda m: m["verbatim"],
    "paraphrased_query": lambda m: m["q_level"] == 1,
    "answerable": lambda m: m.get("answerable", True),
    "unanswerable": lambda m: not m.get("answerable", True),
    **{f"depth{d}": (lambda m, d=d: m["revisions"] == d) for d in range(5)},
}


def outcome(block: str, q: B.Query, ranked_texts: Sequence[str] = ()) -> dict:
    """Prompt-level outcome of one query.

    An answerable query (q.current is not None) is clean when the block holds
    the current value and neither a superseded value nor a same-name other
    person's value. An unanswerable query has no current value, so recall is
    undefined; it is clean exactly when the block states no value of the
    queried slot for any name-matching entity, which is what `wrong` counts on
    those queries. `abstain` records the stronger event of returning no block
    at all. `rank_current` is the 1-based rank of the first shortlisted fact
    holding the current value."""
    answerable = q.current is not None
    cur = answerable and B.contains(block, q.current)
    stale = any(B.contains(block, v) for v in q.stale)
    wrong = any(B.contains(block, v) for v in q.wrong)
    rank = (next((i + 1 for i, t in enumerate(ranked_texts) if B.contains(t, q.current)), None)
            if answerable else None)
    return {"current": cur, "stale": stale, "wrong": wrong, "coinject": cur and stale,
            "clean": (cur or not answerable) and not stale and not wrong,
            "abstain": not block.strip(),
            "answerable": answerable, "rank_current": rank,
            "block_chars": len(block), "n_facts": block.count("\n- ")}


def cluster_id(r: dict) -> str:
    """Resampling unit: the revision chain, taken from the qid so that the same
    chain number in two corpus instances stays two clusters. `q.meta` also
    carries a per-instance chain index, which must not be used for this."""
    return r["qid"].rsplit("-q", 1)[0]


def row(q: B.Query, **fields) -> dict:
    return {"qid": q.qid, **q.meta, "chain": q.qid.rsplit("-q", 1)[0],
            "labels": {"current": q.current, "stale": q.stale, "wrong": q.wrong}, **fields}


def cluster_wilson(rows: Sequence[dict], metric: str) -> tuple:
    """Wilson interval on the number of *chains* with at least one event.
    Used when a bootstrap interval collapses to a point: 0 of 800 chains is
    evidence of a small rate, not of certainty, and this reports that bound."""
    by_chain: Dict[str, bool] = {}
    for r in rows:
        cid = cluster_id(r)
        by_chain[cid] = by_chain.get(cid, False) or bool(r.get(metric))
    k, n = sum(by_chain.values()), len(by_chain)
    _, lo, hi = B.wilson(k, n)
    return lo, hi


def rate(rows: Sequence[dict], metric: str) -> dict:
    k, n = sum(bool(r.get(metric)) for r in rows), len(rows)
    p, lo, hi = B.wilson(k, n)
    return {"rate": p, "lo": lo, "hi": hi, "k": k, "n": n}


def cluster_bootstrap(rows: Sequence[dict], stat: Callable[[List[dict]], float],
                      reps: int = 2000, seed: int = 0) -> tuple:
    """95% percentile CI resampling chains (queries of one chain move together)."""
    by_chain: Dict[str, List[dict]] = defaultdict(list)
    for r in rows:
        by_chain[r.get("cluster") or cluster_id(r)].append(r)
    chains = list(by_chain.values())
    rng = random.Random(seed)
    draws = sorted(stat([r for c in rng.choices(chains, k=len(chains)) for r in c])
                   for _ in range(reps))
    return draws[int(0.025 * reps)], draws[int(0.975 * reps) - 1]


def hier_bootstrap(rows: Sequence[dict], stat: Callable[[List[dict]], float],
                   reps: int = 2000, seed: int = 0) -> tuple:
    """Two-level resample: seeds first, then chains inside each drawn seed.
    Queries of one chain and chains of one corpus instance are not
    independent, and resampling chains alone treats the seed as fixed."""
    by_seed: Dict[object, Dict[str, List[dict]]] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_seed[r.get("seed")][cluster_id(r)].append(r)
    seeds = [list(chains.values()) for chains in by_seed.values()]
    if len(seeds) < 2:
        return cluster_bootstrap(rows, stat, reps, seed)
    rng = random.Random(seed)
    draws = []
    for _ in range(reps):
        sample = []
        for chains in rng.choices(seeds, k=len(seeds)):
            sample += [r for c in rng.choices(chains, k=len(chains)) for r in c]
        draws.append(stat(sample))
    draws.sort()
    return draws[int(0.025 * reps)], draws[int(0.975 * reps) - 1]


def cluster_permutation(a: Sequence[dict], b: Sequence[dict], metric: str = "clean",
                        reps: int = 10_000, seed: int = 0) -> float:
    """Two-sided p for a paired difference, flipping the sign of a whole chain
    at a time. McNemar treats the queries of one revision chain as independent
    trials, which they are not; this test does not."""
    bq = {r["qid"]: r for r in b}
    by_chain: Dict[str, float] = defaultdict(float)
    for r in a:
        by_chain[cluster_id(r)] += int(bool(r.get(metric))) - int(bool(bq[r["qid"]].get(metric)))
    d = list(by_chain.values())
    obs = abs(sum(d))
    if obs == 0:
        return 1.0
    rng = random.Random(seed)
    hits = sum(abs(sum(x if rng.random() < 0.5 else -x for x in d)) >= obs - 1e-12
               for _ in range(reps))
    return (hits + 1) / (reps + 1)


def tost(a: Sequence[dict], b: Sequence[dict], metric: str = "clean",
         margin: float = 0.02, reps: int = 2000, seed: int = 0) -> dict:
    """Two one-sided tests for equivalence within +-`margin`. Equivalence is
    declared when the 90% interval of the paired difference lies inside the
    margin; a non-significant difference test alone never shows equivalence."""
    bq = {r["qid"]: r for r in b}
    pairs = [{"cluster": cluster_id(r), "seed": r.get("seed"),
              "d": int(bool(r.get(metric))) - int(bool(bq[r["qid"]].get(metric)))} for r in a]
    diff = lambda rs: sum(p["d"] for p in rs) / len(rs)
    by_seed: Dict[object, Dict[str, List[dict]]] = defaultdict(lambda: defaultdict(list))
    for p in pairs:
        by_seed[p["seed"]][p["cluster"]].append(p)
    seeds = [list(ch.values()) for ch in by_seed.values()]
    rng = random.Random(seed)
    draws = []
    for _ in range(reps):
        sample = []
        for chains in (rng.choices(seeds, k=len(seeds)) if len(seeds) > 1 else seeds):
            sample += [p for c in rng.choices(chains, k=len(chains)) for p in c]
        draws.append(diff(sample))
    draws.sort()
    lo, hi = draws[int(0.05 * reps)], draws[int(0.95 * reps) - 1]
    p_lo = sum(x <= -margin for x in draws) / reps        # H0: diff <= -margin
    p_hi = sum(x >= margin for x in draws) / reps         # H0: diff >= +margin
    return {"diff": diff(pairs), "ci90": (lo, hi), "margin": margin,
            "p_tost": max(p_lo, p_hi), "equivalent": -margin < lo and hi < margin}


def mean_of(metric: str) -> Callable[[List[dict]], float]:
    return lambda rs: sum(bool(r.get(metric)) for r in rs) / len(rs)


def paired_difference(a: Sequence[dict], b: Sequence[dict], metric: str = "clean",
                      reps: int = 2000, seed: int = 0) -> dict:
    """a - b on the same queries: difference, chain-cluster bootstrap CI, and
    an exact two-sided McNemar test on the discordant query pairs."""
    bq = {r["qid"]: r for r in b}
    pairs = [{"cluster": cluster_id(r), "seed": r.get("seed"),
              "d": int(bool(r.get(metric))) - int(bool(bq[r["qid"]].get(metric)))} for r in a]
    diff = lambda rs: sum(p["d"] for p in rs) / len(rs)
    n01 = sum(p["d"] < 0 for p in pairs)
    n10 = sum(p["d"] > 0 for p in pairs)
    return {"diff": diff(pairs), "ci": cluster_bootstrap(pairs, diff, reps, seed),
            "a_only": n10, "b_only": n01, "mcnemar_p": mcnemar_exact(n10, n01),
            "cluster_p": cluster_permutation(a, b, metric, seed=seed)}


def mcnemar_exact(n10: int, n01: int) -> float:
    n, k = n10 + n01, min(n10, n01)
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def summarize(rows: Sequence[dict], slices: Iterable[str] = ("all",),
              metrics: Iterable[str] = METRICS, ci: bool = True) -> dict:
    out = {}
    for s in slices:
        sub = [r for r in rows if SLICES[s](r)]
        if not sub:
            continue
        cell = {"n": len(sub)}
        for m in metrics:
            cell[m] = sum(bool(r.get(m)) for r in sub) / len(sub)
            if ci:
                lo, hi = hier_bootstrap(sub, mean_of(m))
                cell[f"{m}_ci"] = cluster_wilson(sub, m) if lo == hi else (lo, hi)
        out[s] = cell
    return out


def group(rows: Iterable[dict], *keys: str) -> Dict[tuple, List[dict]]:
    out: Dict[tuple, List[dict]] = defaultdict(list)
    for r in rows:
        out[tuple(r[k] for k in keys)].append(r)
    return out


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, default=list) + "\n")


def read_jsonl(path: Path) -> List[dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh]


def percentile(values: Sequence[float], p: float) -> Optional[float]:
    v = sorted(values)
    if not v:
        return None
    return v[min(len(v) - 1, max(0, math.ceil(p / 100 * len(v)) - 1))]
