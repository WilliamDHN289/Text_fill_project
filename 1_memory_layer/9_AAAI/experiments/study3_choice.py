"""Study 3 — Choice-theoretic serving ablation (three arms + model mismatch).

Simulated accept/reject replay on the large-harness memory (features frozen;
closed-loop heat dynamics are Study 2's territory):

  Arm A  deployed baseline: global-constant fusion score (Eq. 1), top-k
  Arm B  online-MLE per-user fusion weights (MNL utility), top-k
  Arm C  online MLE + constrained assortment injection (exact DP under
         cardinality k and character budget B)

True user behavior is simulated from persona parameters theta* with a
relevance boost on ground-truth facts. The model-mismatch robustness check
simulates users with *mixed* logit (theta drawn per episode) and *nested*
logit (facts sharing their first entity form a nest, within-nest
correlation lambda), while estimation and optimization stay MNL --- the
circularity guard the paper promises. Metrics: true acceptance probability,
NDCG@k, ground-truth fact injection rate, injected characters, and
acceptance per 100 injected characters; plus the fraction of the C-over-A
gain that survives mismatch (gain retention).
"""

from __future__ import annotations

import math
import random
from typing import Dict, List, Sequence

import common
import corpus as C

FEATURES = ("bm25", "rec", "heat", "assoc", "bias")  # bm25 enters as log1p


# --------------------------------------------------------------------------
# Candidate preparation
# --------------------------------------------------------------------------

def _feature_vec(cand: dict) -> List[float]:
    return [math.log1p(cand["bm25"]), cand["rec"], cand["heat"],
            cand["assoc"], 1.0]


def prepare_scenarios(cfg: dict, rng: random.Random) -> List[dict]:
    """Build the large memory, inject a synthetic usage history (so the heat
    feature has variance), and freeze per-scenario candidate features."""
    s3 = cfg["study3"]
    mem = common.build_memory(cfg["dpfm"], C.large_corpus())

    # Synthetic usage history: Poisson-ish accepted-use counts per fact,
    # spread over the past two weeks (mark_used also refreshes recency,
    # exactly as the deployed feedback path does).
    mean_uses = s3["usage_history_mean"]
    for fid in list(mem.facts.keys()):
        uses = 0
        while rng.random() < mean_uses / (1.0 + uses):  # geometric-ish, mean ~ mean_uses
            uses += 1
            mem.mark_used([fid], now=C.BASE - rng.uniform(0, 14) * C.DAY)
            if uses > 6:
                break

    scen = []
    for sc in C.LARGE_SCENARIOS:
        if not sc.expect_hit:
            continue
        cands = common.retrieve_candidates(mem, sc.prefix, [sc.partner],
                                           C.BASE, s3["shortlist"])
        if len(cands) < 2:
            continue
        overhead = s3["line_overhead"]
        items = []
        for cd in cands:
            items.append({
                "x": _feature_vec(cd),
                "cost": cd["len"] + overhead,
                "score": cd["score"],                       # deployed Eq.-1 score
                "is_truth": C.prompt_contains(cd["text"], sc.truth),
                "nest": cd["entities"][0] if cd["entities"] else f"solo{cd['fact_id']}",
            })
        scen.append({"category": sc.category, "items": items})
    return scen


# --------------------------------------------------------------------------
# True user model
# --------------------------------------------------------------------------

def _theta_from_persona(p: dict) -> List[float]:
    return [p["bm25"], p["rec"], p["heat"], p["assoc"], p["bias"]]


def true_attractions(items: List[dict], theta: Sequence[float],
                     boost: float, clip: float) -> List[float]:
    out = []
    for it in items:
        u = sum(t * x for t, x in zip(theta, it["x"])) + boost * it["is_truth"]
        out.append(math.exp(max(-clip, min(clip, u))))
    return out


def accept_prob(sel: List[int], w: List[float], items: List[dict],
                model: str, lam: float) -> float:
    if not sel:
        return 0.0
    if model in ("mnl", "mixed"):
        W = sum(w[i] for i in sel)
        return W / (1.0 + W)
    # nested logit: nests share the first entity
    nests: Dict[str, float] = {}
    for i in sel:
        nests[items[i]["nest"]] = nests.get(items[i]["nest"], 0.0) \
            + w[i] ** (1.0 / lam)
    W = sum(v ** lam for v in nests.values())
    return W / (1.0 + W)


# --------------------------------------------------------------------------
# Arms
# --------------------------------------------------------------------------

def _truncate_by_budget(order: List[int], items: List[dict], k: int,
                        budget: int) -> List[int]:
    """Mirror _format_prompt: take ranked facts, stop at first overflow."""
    sel, used = [], 0
    for i in order:
        if len(sel) >= k:
            break
        if used + items[i]["cost"] > budget:
            break
        sel.append(i)
        used += items[i]["cost"]
    return sel


def select_topk_score(items: List[dict], k: int, budget: int) -> List[int]:
    order = sorted(range(len(items)), key=lambda i: -items[i]["score"])
    return _truncate_by_budget(order, items, k, budget)


def estimated_attractions(items: List[dict], theta: Sequence[float],
                          clip: float) -> List[float]:
    out = []
    for it in items:
        u = sum(t * x for t, x in zip(theta, it["x"]))
        out.append(math.exp(max(-clip, min(clip, u))))
    return out


def select_topk_utility(items: List[dict], w_hat: List[float], k: int,
                        budget: int) -> List[int]:
    order = sorted(range(len(items)), key=lambda i: -w_hat[i])
    return _truncate_by_budget(order, items, k, budget)


def select_assortment_dp(items: List[dict], w_hat: List[float], k: int,
                         budget: int, unit: int) -> List[int]:
    """Exact DP for max sum(w_hat) s.t. |S|<=k, sum(cost)<=budget.
    (Under MNL the acceptance probability is monotone in the attraction sum,
    so this solves Eq. 4 of the paper exactly up to budget discretization.)"""
    nb = budget // unit
    n = len(items)
    NEG = float("-inf")
    # dp[c][b] = best attraction sum with exactly-c items and <=b budget units
    dp = [[NEG] * (nb + 1) for _ in range(k + 1)]
    dp[0] = [0.0] * (nb + 1)
    take = [[[False] * (nb + 1) for _ in range(k + 1)] for _ in range(n)]
    for i in range(n):
        cost_u = max(1, math.ceil(items[i]["cost"] / unit))
        wi = w_hat[i]
        ti = take[i]
        for c in range(min(i + 1, k), 0, -1):
            row, prev = dp[c], dp[c - 1]
            for b in range(nb, cost_u - 1, -1):
                cand = prev[b - cost_u]
                if cand > NEG and cand + wi > row[b]:
                    row[b] = cand + wi
                    ti[c][b] = True
    # best cell
    best_c, best_b, best_v = 0, 0, 0.0
    for c in range(k + 1):
        for b in range(nb + 1):
            if dp[c][b] > best_v:
                best_c, best_b, best_v = c, b, dp[c][b]
    # backtrack
    sel: List[int] = []
    c, b = best_c, best_b
    for i in range(n - 1, -1, -1):
        if c == 0:
            break
        if take[i][c][b]:
            sel.append(i)
            b -= max(1, math.ceil(items[i]["cost"] / unit))
            c -= 1
    sel.reverse()
    return sel


# --------------------------------------------------------------------------
# Online MLE (single SGD step per observation, as on the cold path)
# --------------------------------------------------------------------------

def sgd_step(theta: List[float], sel: List[int], items: List[dict],
             y: int, lr: float, l2: float, clip: float) -> None:
    if not sel:
        return
    w = estimated_attractions([items[i] for i in sel], theta, clip)
    W = sum(w)
    sx = [0.0] * len(theta)
    for wi, i in zip(w, sel):
        for d, xd in enumerate(items[i]["x"]):
            sx[d] += wi * xd
    if y == 1:
        coef = 1.0 / W - 1.0 / (1.0 + W)
    else:
        coef = -1.0 / (1.0 + W)
    for d in range(len(theta)):
        theta[d] += lr * (coef * sx[d] - l2 * theta[d])


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------

def ndcg_at_k(sel: List[int], w_true: List[float], k: int) -> float:
    if not sel:
        return 0.0
    dcg = sum(w_true[i] / math.log2(r + 2) for r, i in enumerate(sel[:k]))
    ideal = sorted(w_true, reverse=True)[:k]
    idcg = sum(g / math.log2(r + 2) for r, g in enumerate(ideal))
    return dcg / idcg if idcg > 0 else 0.0


# --------------------------------------------------------------------------
# Simulation
# --------------------------------------------------------------------------

def simulate(cfg: dict, scenarios: List[dict], user_model: str,
             persona_name: str, seed: int, budget: int) -> dict:
    s3 = cfg["study3"]
    rng = random.Random(f"{seed}/{user_model}/{persona_name}/{budget}")  # deterministic
    theta_star = _theta_from_persona(s3["personas"][persona_name])
    boost, clip = s3["relevance_boost"], s3["utility_clip"]
    k = cfg["dpfm"]["retrieval"]["k"]
    unit = s3["char_unit"]
    lam = s3["nested_lambda"]
    sigma = s3["mixed_sigma"]
    warmup = int(s3["episodes"] * s3["warmup_frac"])

    theta_B = [0.0] * len(FEATURES)
    theta_C = [0.0] * len(FEATURES)
    stats = {arm: {"acc": [], "realized": [], "ndcg": [], "truth": [],
                   "chars": []} for arm in "ABC"}

    for ep in range(s3["episodes"]):
        scen = scenarios[rng.randrange(len(scenarios))]
        items = scen["items"]

        theta_ep = list(theta_star)
        if user_model == "mixed":
            theta_ep = [t + rng.gauss(0.0, sigma) for t in theta_star]
        w_true = true_attractions(items, theta_ep, boost, clip)

        w_hat_B = estimated_attractions(items, theta_B, clip)
        w_hat_C = estimated_attractions(items, theta_C, clip)

        sels = {
            "A": select_topk_score(items, k, budget),
            "B": select_topk_utility(items, w_hat_B, k, budget),
            "C": select_assortment_dp(items, w_hat_C, k, budget, unit),
        }
        u = rng.random()  # common random number across arms
        for arm, sel in sels.items():
            p = accept_prob(sel, w_true, items, user_model, lam)
            y = 1 if u < p else 0
            if arm == "B":
                sgd_step(theta_B, sel, items, y, s3["lr"], s3["l2"], clip)
            elif arm == "C":
                sgd_step(theta_C, sel, items, y, s3["lr"], s3["l2"], clip)
            if ep >= warmup:
                st = stats[arm]
                st["acc"].append(p)
                st["realized"].append(y)
                # each arm is scored on its *own* injection order
                # (A: deployed score; B: estimated utility; C: DP set
                # ordered by estimated utility)
                order = (sorted(sel, key=lambda i: -w_hat_C[i])
                         if arm == "C" else sel)
                st["ndcg"].append(ndcg_at_k(order, w_true, k))
                st["truth"].append(
                    1.0 if any(items[i]["is_truth"] for i in sel) else 0.0)
                st["chars"].append(float(sum(items[i]["cost"] for i in sel)))

    def agg(st):
        n = max(1, len(st["acc"]))
        acc = sum(st["acc"]) / n
        chars = sum(st["chars"]) / n
        return {
            "acceptance_true": round(acc, 4),
            "acceptance_realized": round(sum(st["realized"]) / n, 4),
            "ndcg_at_k": round(sum(st["ndcg"]) / n, 4),
            "truth_injected_rate": round(sum(st["truth"]) / n, 4),
            "injected_chars_mean": round(chars, 1),
            "acceptance_per_100_chars": round(acc / chars * 100.0, 4) if chars else 0.0,
        }

    return {
        "user_model": user_model, "persona": persona_name, "seed": seed,
        "budget": budget,
        "arms": {arm: agg(st) for arm, st in stats.items()},
        "theta_star": dict(zip(FEATURES, [round(t, 3) for t in theta_star])),
        "theta_hat_B": dict(zip(FEATURES, [round(t, 3) for t in theta_B])),
        "theta_hat_C": dict(zip(FEATURES, [round(t, 3) for t in theta_C])),
    }


def run(cfg: dict, out_dir) -> dict:
    s3 = cfg["study3"]
    rng = random.Random(cfg["seed"])
    scenarios = prepare_scenarios(cfg, rng)

    budgets = s3.get("budgets") or [cfg["dpfm"]["retrieval"]["prompt_char_budget"]]
    runs = []
    for budget in budgets:
        for user_model in s3["user_models"]:
            for persona in s3["personas"]:
                for seed in s3["seeds"]:
                    runs.append(simulate(cfg, scenarios, user_model, persona,
                                         seed, budget))

    # aggregate over seeds: mean acceptance per (model, persona, budget, arm)
    agg: Dict[str, Dict[str, Dict[str, float]]] = {}
    for r in runs:
        key = f"{r['user_model']}/{r['persona']}/b{r['budget']}"
        cell = agg.setdefault(key, {a: {"acc": 0.0, "chars": 0.0, "ndcg": 0.0,
                                        "truth": 0.0, "n": 0}
                                    for a in "ABC"})
        for a in "ABC":
            cell[a]["acc"] += r["arms"][a]["acceptance_true"]
            cell[a]["chars"] += r["arms"][a]["injected_chars_mean"]
            cell[a]["ndcg"] += r["arms"][a]["ndcg_at_k"]
            cell[a]["truth"] += r["arms"][a]["truth_injected_rate"]
            cell[a]["n"] += 1
    table = {}
    for key, cell in agg.items():
        table[key] = {a: {m: round(cell[a][m] / cell[a]["n"], 4)
                          for m in ("acc", "chars", "ndcg", "truth")}
                      for a in "ABC"}

    # gain retention: (C - A) under mismatch / (C - A) under MNL,
    # per persona and budget
    retention = {}
    for budget in budgets:
        for persona in s3["personas"]:
            base = table.get(f"mnl/{persona}/b{budget}")
            if not base:
                continue
            gain_mnl = base["C"]["acc"] - base["A"]["acc"]
            for model in s3["user_models"]:
                if model == "mnl":
                    continue
                cell = table.get(f"{model}/{persona}/b{budget}")
                if cell and abs(gain_mnl) > 1e-9:
                    retention[f"{model}/{persona}/b{budget}"] = round(
                        (cell["C"]["acc"] - cell["A"]["acc"]) / gain_mnl, 3)

    result = {
        "status": "DONE",
        "n_scenarios_used": len(scenarios),
        "config_used": {key: s3[key] for key in
                        ("episodes", "warmup_frac", "shortlist", "seeds", "lr",
                         "l2", "char_unit", "relevance_boost", "mixed_sigma",
                         "nested_lambda", "budgets")},
        "table": table,
        "gain_retention_C_over_A": retention,
        "runs": runs,
    }
    common.write_json(out_dir / "study3.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 3: {r.get('status')}"
    lines = ["Study 3 (acceptance_true / injected chars, mean over seeds):"]
    for key in sorted(r["table"]):
        cell = r["table"][key]
        lines.append(
            f"  {key:22s} A {cell['A']['acc']:.3f}/{cell['A']['chars']:.0f}c  "
            f"B {cell['B']['acc']:.3f}/{cell['B']['chars']:.0f}c  "
            f"C {cell['C']['acc']:.3f}/{cell['C']['chars']:.0f}c")
    if r["gain_retention_C_over_A"]:
        ret = ", ".join(f"{k}={v}" for k, v in
                        sorted(r["gain_retention_C_over_A"].items()))
        lines.append(f"  gain retention under mismatch: {ret}")
    return "\n".join(lines)
