"""Study 4 — Baselines and ablations under the on-device budget.

Each internal ablation maps to one failure mode of the paper's typology,
turning the gap argument into measurement on the large harness:

  pfm_full         the deployed configuration (reference)
  no_participants  participants field weight 0 + query boost 0
                   -> identity grounding off (misattribution risk)
  no_graph         assoc_gamma = 0 -> associative scenarios must degrade
  no_recency       recency multiplier forced to 1 -> conflict scenario
                   (newest-of-two-contradicting-facts) must degrade
  recency_only     rank purely by last_reinforced (no lexical evidence)
  random_k         uniform random k facts (floor)

External server-assumption baselines (Mem0 OSS, LangMem) are attempted via
import; when unavailable (no package / no API key) they are recorded as
SKIPPED with the reason --- running them faithfully requires the embedding
and LLM services whose absence on-device is precisely the paper's point.

Metrics: fact availability (overall and per category), retrieval latency,
deadline violations against study4.deadline_ms, plus two probes the plain
availability metric cannot see:

  identity probes    pairs of near-identical facts sent to different
                     partners, queried from each partner's window; success =
                     the correct partner's value outranks the other one.
                     (Additions beyond the Swift harness --- the ported
                     scenarios carry enough lexical signal that the
                     participant field is not load-bearing for them.)
  stale co-injection on the conflict scenario, is the *superseded* value
                     ("friday 10am") also present in the block? The rule
                     extractor emits no slot keys, so bitemporal supersession
                     cannot fire and recency ordering is the only defense ---
                     this measures exactly the limitation the paper states.
"""

from __future__ import annotations

import copy
import importlib
import random
import time
from typing import List

import common
import corpus as C


# --------------------------------------------------------------------------
# Variant configurations
# --------------------------------------------------------------------------

def _variant_cfg(dcfg: dict, name: str) -> dict:
    v = copy.deepcopy(dcfg)
    if name == "no_participants":
        v["scoring"]["field_weight_participants"] = 0.0
        v["retrieval"]["participant_boost"] = 0.0
    elif name == "no_graph":
        v["scoring"]["assoc_gamma"] = 0.0
    elif name == "no_recency":
        v["scoring"]["recency_floor"] = 1.0  # multiplier == 1 everywhere
    return v


def _format_block(mem, facts) -> str:
    """Same budgeted formatting as dpfm._format_prompt (for the degenerate
    baselines that bypass mem.retrieve)."""
    if not facts:
        return ""
    lines, used = ["[Relevant memory]"], 0
    for f in facts:
        line = f"- {f.text}"
        if used + len(line) > mem.prompt_char_budget:
            break
        lines.append(line)
        used += len(line)
    return "\n".join(lines) if len(lines) > 1 else ""


def _replay_variant(mem, name: str, k: int, repeats: int,
                    deadline_ms: float, rng: random.Random) -> dict:
    hits = 0
    by_cat: dict = {}
    lat: List[float] = []
    valid = [f for f in mem.facts.values() if f.valid]

    for sc in C.LARGE_SCENARIOS:
        if name == "recency_only":
            top = sorted(valid, key=lambda f: -f.last_reinforced)[:k]
            block = _format_block(mem, top)
        elif name == "random_k":
            block = _format_block(mem, rng.sample(valid, min(k, len(valid))))
        else:
            snap = mem.retrieve(sc.prefix, participants=[sc.partner],
                                k=k, now=C.BASE)
            block = snap.prompt_block
        hit = C.prompt_contains(block, sc.truth)
        hits += hit
        cell = by_cat.setdefault(sc.category, {"hit": 0, "n": 0})
        cell["n"] += 1
        cell["hit"] += hit

    if name not in ("recency_only", "random_k"):
        for _ in range(repeats):
            for sc in C.LARGE_SCENARIOS:
                lat.append(mem.retrieve(sc.prefix, participants=[sc.partner],
                                        k=k, now=C.BASE).latency_ms)
    violations = sum(1 for v in lat if v > deadline_ms)
    return {
        "availability": f"{hits}/{len(C.LARGE_SCENARIOS)}",
        "by_category": by_cat,
        "latency": common.latency_summary(lat) if lat else None,
        "deadline_violations": violations,
    }


# --------------------------------------------------------------------------
# Identity probes: near-identical facts, different partners, same day.
# Queried from each partner's window; only participant attribution can
# break the lexical tie. (days_ago identical so recency cannot.)
# --------------------------------------------------------------------------

IDENTITY_PROBES = [
    # (partner_a, value_a, partner_b, value_b, fact_template, query_prefix)
    ("Alice Chen", "9am",     "Bob Park",   "11am",
     "Our weekly standup moved to {v}.",        "Reminder: our weekly standup is at "),
    ("Carol Wu",   "March 6", "Dan Lee",    "March 9",
     "The vendor demo is scheduled for {v}.",   "The vendor demo will be on "),
    ("Erin Gomez", "3pm",     "Frank Liu",  "4pm",
     "The follow-up call is scheduled for {v}.", "Our follow-up call is at "),
    ("HR Desk",    "12F",     "IT Support", "47B",
     "The parking spot is {v}.",                "My assigned parking spot is "),
]
PROBE_DAYS_AGO = 3.0


def _probe_messages():
    msgs = []
    for pa, va, pb, vb, tmpl, _ in IDENTITY_PROBES:
        msgs.append((PROBE_DAYS_AGO, pa, tmpl.format(v=va)))
        msgs.append((PROBE_DAYS_AGO, pb, tmpl.format(v=vb)))
    return msgs


def _run_identity_probes(mem, k: int) -> dict:
    """Each pair is queried from both partners' windows: 8 measurements.
    Success = correct value present and ranked above the wrong value
    (absent wrong value also counts)."""
    correct = total = 0
    details = []
    for pa, va, pb, vb, _tmpl, prefix in IDENTITY_PROBES:
        for partner, good, bad in ((pa, va, vb), (pb, vb, va)):
            snap = mem.retrieve(prefix, participants=[partner],
                                k=k, now=C.BASE)
            low = snap.prompt_block.lower()
            gi, bi = low.find(good.lower()), low.find(bad.lower())
            ok = gi >= 0 and (bi < 0 or gi < bi)
            correct += ok
            total += 1
            details.append({"partner": partner, "expects": good,
                            "good_pos": gi, "bad_pos": bi, "ok": ok})
    return {"accuracy": f"{correct}/{total}", "details": details}


def _stale_coinjection(mem, k: int) -> bool:
    """Conflict scenario: is the superseded 'friday 10am' co-injected next
    to the current 'monday 2pm'?"""
    sc = next(s for s in C.LARGE_SCENARIOS if s.category == "conflict")
    snap = mem.retrieve(sc.prefix, participants=[sc.partner], k=k, now=C.BASE)
    return "friday 10am" in snap.prompt_block.lower()


# --------------------------------------------------------------------------
# External baselines (graceful skip)
# --------------------------------------------------------------------------

def _try_external(name: str) -> dict:
    mod_name = {"mem0": "mem0", "langmem": "langmem"}.get(name, name)
    try:
        importlib.import_module(mod_name)
    except ImportError:
        return {"status": "SKIPPED",
                "reason": (f"package '{mod_name}' not installed. Install it and "
                           f"add an adapter in study4_baselines.py; note both "
                           f"systems require embedding/LLM services, so a "
                           f"faithful edge-budget run must stub or locally "
                           f"host those and count their latency against the "
                           f"deadline.")}
    return {"status": "TODO",
            "reason": (f"package '{mod_name}' is installed but the adapter is "
                       f"not implemented yet (needs API-key/config decisions "
                       f"that should not be made silently). Implement "
                       f"an adapter mirroring _replay_variant.")}


# --------------------------------------------------------------------------

def run(cfg: dict, out_dir) -> dict:
    s4 = cfg["study4"]
    k = cfg["dpfm"]["retrieval"]["k"]
    rng = random.Random(cfg["seed"])
    messages = C.large_corpus()

    probe_messages = messages + _probe_messages()
    variants = {}
    for name in s4["variants"]:
        vcfg = _variant_cfg(cfg["dpfm"], name)
        mem = common.build_memory(vcfg, messages)
        v = _replay_variant(mem, name, k, s4["latency_repeats"],
                            s4["deadline_ms"], rng)
        if name not in ("recency_only", "random_k"):
            v["stale_coinjection"] = _stale_coinjection(mem, k)
            # probes evaluated on a separate memory so the main replay
            # stays identical to the ported Swift harness
            probe_mem = common.build_memory(vcfg, probe_messages)
            v["identity_probes"] = _run_identity_probes(probe_mem, k)
        variants[name] = v

    external = {name: _try_external(name) for name in s4.get("external", [])}

    result = {"status": "DONE", "deadline_ms": s4["deadline_ms"],
              "variants": variants, "external": external}
    common.write_json(out_dir / "study4.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 4: {r.get('status')}"
    lines = ["Study 4 (availability on the large harness; deadline "
             f"{r['deadline_ms']}ms):"]
    for name, v in r["variants"].items():
        cats = ", ".join(f"{c} {cell['hit']}/{cell['n']}"
                         for c, cell in sorted(v["by_category"].items()))
        lat = (f", p95={v['latency']['p95_ms']}ms, "
               f"violations={v['deadline_violations']}") if v["latency"] else ""
        extra = ""
        if "identity_probes" in v:
            extra = (f", identity {v['identity_probes']['accuracy']}, "
                     f"stale_coinject={v['stale_coinjection']}")
        lines.append(f"  {name:16s} {v['availability']} ({cats}){lat}{extra}")
    for name, e in r["external"].items():
        lines.append(f"  {name:16s} {e['status']}")
    return "\n".join(lines)
