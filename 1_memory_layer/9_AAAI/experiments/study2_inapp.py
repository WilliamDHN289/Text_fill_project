"""Study 2 — In-app A/B analyzer.

The live A/B (protocol in ../../8_dpfm_application/docs/DPFM-EXPERIMENT.md,
stage 2) requires real usage data from the deployed assistant: the only
variable is the memory feature flag, flipped by day; the app logs
{arm, accepted, words_saved, latency_ms, ts} events.

This module analyzes an exported JSONL of those events. Without a log file
it reports SKIPPED — honestly: this study cannot be simulated offline, and
the paper must keep its Study-2 claims as protocol-only until the log exists.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import common


def _welch_t(a, b) -> float:
    """Welch's t statistic (no scipy dependency); returns nan when degenerate."""
    na, nb = len(a), len(b)
    if na < 2 or nb < 2:
        return float("nan")
    ma, mb = sum(a) / na, sum(b) / nb
    va = sum((x - ma) ** 2 for x in a) / (na - 1)
    vb = sum((x - mb) ** 2 for x in b) / (nb - 1)
    denom = math.sqrt(va / na + vb / nb)
    return (mb - ma) / denom if denom > 0 else float("nan")


def run(cfg: dict, out_dir) -> dict:
    log_path = cfg["study2"].get("log_path") or ""
    if not log_path or not Path(log_path).exists():
        result = {
            "status": "SKIPPED",
            "reason": ("No in-app A/B log provided (study2.log_path is empty "
                       "or missing). This study requires real usage from the "
                       "deployed assistant and cannot be simulated offline."),
            "protocol": {
                "variable": "dpfm.yaml enabled flag, flipped per day",
                "control": "memory layer never constructed (zero overhead)",
                "metrics": ["acceptance rate", "words saved per accepted "
                            "completion", "latency regression guard"],
                "event_schema": {"arm": "A|B", "accepted": "bool",
                                 "words_saved": "int", "latency_ms": "float",
                                 "ts": "float"},
            },
        }
        common.write_json(out_dir / "study2.json", result)
        return result

    arms = {"A": [], "B": []}
    with open(log_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            if ev.get("arm") in arms:
                arms[ev["arm"]].append(ev)

    def agg(events):
        n = len(events)
        acc = [1.0 if e.get("accepted") else 0.0 for e in events]
        ws = [float(e.get("words_saved", 0)) for e in events if e.get("accepted")]
        lat = sorted(float(e.get("latency_ms", 0)) for e in events)
        return {
            "n": n,
            "acceptance_rate": round(sum(acc) / n, 4) if n else float("nan"),
            "words_saved_mean": round(sum(ws) / len(ws), 3) if ws else float("nan"),
            "latency": common.latency_summary(lat),
        }

    result = {
        "status": "DONE",
        "arm_A": agg(arms["A"]),
        "arm_B": agg(arms["B"]),
        "welch_t_acceptance": round(_welch_t(
            [1.0 if e.get("accepted") else 0.0 for e in arms["A"]],
            [1.0 if e.get("accepted") else 0.0 for e in arms["B"]]), 3),
    }
    common.write_json(out_dir / "study2.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return "Study 2: SKIPPED (no in-app log; protocol-only, as stated in the paper)"
    return (f"Study 2: acceptance A={r['arm_A']['acceptance_rate']} "
            f"B={r['arm_B']['acceptance_rate']} (Welch t={r['welch_t_acceptance']}); "
            f"words saved A={r['arm_A']['words_saved_mean']} "
            f"B={r['arm_B']['words_saved_mean']}")
