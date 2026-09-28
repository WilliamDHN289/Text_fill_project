"""Run the experiments behind every table and figure.

    python3.11 run_all.py                    # everything
    python3.11 run_all.py --only baselines   # one experiment
    python3.11 run_all.py --smoke            # tiny sizes, checks the pipeline

Outputs go to results/<timestamp>/: per-query JSONL logs, per-experiment
JSON, the exact config used, and the environment. `make_report.py` turns a
results directory into the paper's tables and figures.
"""

from __future__ import annotations

import argparse
import copy
import time
from pathlib import Path

import yaml

import common as C
import exp_ablation
import exp_baselines
import exp_crossover
import exp_extractor
import exp_identity
import exp_keynoise
import exp_llm
import exp_real
import exp_scaling
import exp_serving
import exp_systems
import exp_slices
import exp_temporal

EXPERIMENTS = {"temporal": exp_temporal, "baselines": exp_baselines, "ablation": exp_ablation,
               "keynoise": exp_keynoise, "slices": exp_slices, "extractor": exp_extractor, "serving": exp_serving,
               "scaling": exp_scaling, "crossover": exp_crossover, "llm": exp_llm,
               "real": exp_real, "identity": exp_identity,
               "systems": exp_systems}


def smoke(cfg: dict) -> dict:
    cfg = copy.deepcopy(cfg)
    cfg["benchmark"].update(n_chains=30, seeds=[7, 11], fillers={"lean": 0, "noisy": 100})
    cfg["baselines"]["latency_repeats"] = 1
    cfg["key_noise"].update(p_miss=[0.0, 0.2], q_false=[0.0, 0.1])
    cfg["slices"].update(multi_valued_people=6, hard_pairs=4)
    cfg["serving"].update(requests=100, store_facts=2000)
    cfg["scaling"].update(grid=[100, 2000], queries=50)
    cfg["crossover"].update(grid=[1000, 5000], queries=20)
    cfg["llm"].update(arms=["none", "pfm"], models=["qwen2:7b"],
                      retrieval_during_generation=10)
    cfg["extractor"].update(corpus="lean", models=["llama3.2:3b"], seeds=[7, 11])
    cfg["real"].update(dense=False, foreign_per_conversation=3, distractors=10)
    cfg["systems"]["seeds"] = 1
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", choices=sorted(EXPERIMENTS))
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--config", default=None, help="parameter file to use instead of config.yaml")
    ap.add_argument("--out", default=None, help="write into an existing results directory")
    args = ap.parse_args()

    cfg = C.load_config(Path(args.config) if args.config else None)
    if args.smoke:
        cfg = smoke(cfg)
    out = C.ROOT / (args.out or f"results/{time.strftime('%Y%m%d-%H%M%S')}"
                    f"{'-smoke' if args.smoke else ''}")
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "config_used.yaml", "w") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    C.write_json(out / "env.json", C.env_info())

    for name in args.only or EXPERIMENTS:
        t0 = time.time()
        print(f"=== {name} ===", flush=True)
        EXPERIMENTS[name].run(cfg, out)
        print(f"    {time.time() - t0:.0f}s", flush=True)
    print(f"results: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
