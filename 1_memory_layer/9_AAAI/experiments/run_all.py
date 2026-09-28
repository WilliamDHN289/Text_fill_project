"""Run every experiment in aaai2027_full.tex (Studies 1-4).

Usage:
    python3 run_all.py                 # full run, config.yaml
    python3 run_all.py --smoke         # fast smoke test (reduced sizes)
    python3 run_all.py --only study3   # single study
    python3 run_all.py --config other.yaml

Results land in results/<timestamp>/: per-study JSON, the config copy,
and report.md summarizing everything against the paper's expected numbers.
"""

from __future__ import annotations

import argparse
import copy
import time
import traceback
from pathlib import Path

import yaml

import common
import study1_replay
import study2_inapp
import study3_choice
import study4_baselines
import study5_temporal
import study6_baselines
import study7_llm
import study8_scaling

STUDIES = {
    "study1": study1_replay,
    "study2": study2_inapp,
    "study3": study3_choice,
    "study4": study4_baselines,
    "study5": study5_temporal,
    "study6": study6_baselines,
    "study7": study7_llm,
    "study8": study8_scaling,
}


def _smoke_overrides(cfg: dict) -> dict:
    cfg = copy.deepcopy(cfg)
    cfg["study1"]["latency_repeats"] = 2
    cfg["study1"]["stress"].update(n_facts=2000, n_runs=50)
    cfg["study3"].update(episodes=120, seeds=[1], user_models=["mnl"])
    cfg["study4"]["latency_repeats"] = 2
    cfg["study5"].update(n_chains=30, corpora={"lean": 0, "noisy": 150})
    cfg["study6"].update(n_latency_repeats=1)
    cfg["study7"].update(n_queries=4)
    cfg["study8"].update(grid=[100, 2000], n_queries=80)
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=None)
    ap.add_argument("--only", choices=sorted(STUDIES), default=None)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()

    cfg = common.load_config(Path(args.config) if args.config else None)
    if args.smoke:
        cfg = _smoke_overrides(cfg)

    stamp = time.strftime("%Y%m%d-%H%M%S") + ("-smoke" if args.smoke else "")
    out_dir = common.EXP_DIR / cfg["output_dir"] / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    with open(out_dir / "config_used.yaml", "w", encoding="utf-8") as fh:
        yaml.safe_dump(cfg, fh, allow_unicode=True, sort_keys=False)

    header = f"AAAI-27 experiment run {stamp} | {common.env_info()}"
    print(header, flush=True)

    summaries, statuses = [], {}
    for name, mod in STUDIES.items():
        if args.only and name != args.only:
            continue
        if not cfg["studies"].get(name, False):
            statuses[name] = "DISABLED"
            summaries.append(f"{name}: DISABLED in config")
            continue
        t0 = time.time()
        print(f"\n=== {name} ===", flush=True)
        try:
            result = mod.run(cfg, out_dir)
            statuses[name] = result.get("status", "DONE")
            line = mod.summarize(result)
        except Exception:
            statuses[name] = "ERROR"
            line = f"{name}: ERROR\n{traceback.format_exc()}"
        line += f"\n  [{time.time() - t0:.1f}s]"
        print(line, flush=True)
        summaries.append(line)

    report = "\n\n".join(
        [f"# Experiment report — {stamp}", f"`{common.env_info()}`",
         "Statuses: " + ", ".join(f"{k}={v}" for k, v in statuses.items())]
        + [f"```\n{s}\n```" for s in summaries]
        + ["Paper cross-check: Study-1 availability/extraction must match "
           "aaai2027_full.tex Tables 2-4 (Swift reference numbers in "
           "study1.json expected_from_paper); Study-3 feeds the "
           "Choice-Theoretic Serving section; Study-4 feeds the baselines "
           "subsection. Latency absolute values are Python-implementation "
           "numbers — the paper's Swift release-build numbers remain the "
           "deployment claim."])
    with open(out_dir / "report.md", "w", encoding="utf-8") as fh:
        fh.write(report + "\n")

    print(f"\nAll done. Results: {out_dir}", flush=True)
    return 0 if all(v in ("DONE", "SKIPPED", "DISABLED")
                    for v in statuses.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
