"""Config loading, benchmark and store construction, run metadata."""

from __future__ import annotations

import copy
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Optional

import yaml

import arms as A
import benchmark as B
import extractor as X
import metrics as M
import pfm

ROOT = Path(__file__).resolve().parent


def load_config(path: Optional[Path] = None) -> dict:
    with open(path or ROOT / "config.yaml", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def merged(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in override.items():
        out[k] = merged(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def make_bench(cfg: dict, seed: int, corpus: str) -> B.Bench:
    b = cfg["benchmark"]
    return B.generate(b["n_chains"], seed, b["fillers"][corpus], b["p_cancel"],
                      {int(k): v for k, v in b["rev_weights"].items()}, f"{corpus}-s{seed}")


def build_store(pfm_cfg: dict, bench: B.Bench, keyed: bool = True,
                noise: Optional[tuple] = None, granularity: str = "slot",
                extractor=None) -> pfm.PFM:
    """Ingest the benchmark stream in arrival order. noise = (p_miss, q_false, seed)."""
    ex = extractor or X.make_keyed_extractor(bench.gazetteer, granularity)
    if not keyed:
        ex = X.strip_keys(ex)
    if noise is not None:
        ex = X.with_key_noise(ex, *noise)
    store = pfm.PFM(pfm_cfg, ex)
    for days_ago, partner, text in bench.messages:
        parts = [partner] if isinstance(partner, str) else list(partner)
        store.ingest(text, parts, B.BASE - days_ago * B.DAY)
    store.extractor_log = getattr(ex, "log", None)
    return store


def reachable(store: pfm.PFM, queries) -> set:
    """qids whose current value is held by some active fact."""
    active = "\n".join(f.text for f in store.facts.values() if f.active)
    return {q.qid for q in queries if B.contains(active, q.current)}


def evaluate(arm: A.Arm, bench: B.Bench, k: int, budget: int, **tags) -> list:
    """One per-query row for every benchmark query."""
    rows = []
    for q in bench.queries:
        block, ranked, ms = A.serve(arm, q.prefix, [q.partner], B.BASE, k, budget)
        rows.append(M.row(q, arm=arm.name, budget=budget, **tags,
                          **M.outcome(block, q, [f.text for f, _ in ranked]), latency_ms=ms))
    return rows


def env_info() -> dict:
    def sh(*cmd):
        try:
            return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
        except Exception:
            return None
    return {"python": sys.version.split()[0], "platform": platform.platform(),
            "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"),
            "cores": sh("sysctl", "-n", "hw.ncpu"), "ram_bytes": sh("sysctl", "-n", "hw.memsize"),
            "commit": sh("git", "-C", str(ROOT), "rev-parse", "--short", "HEAD")}


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, default=list)
