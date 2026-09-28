#!/usr/bin/env python3
"""Autocomplete harness with optional DPHM memory layer.

Compares base llama.cpp completion vs shallow-fusion DPHM on the same cut
points. All parameters live in config.yaml (override with --config).

Usage:
  ./run_server.sh models/gemma-4-E2B-base-Q4_K_M.gguf 99 &
  python3 harness_dphm.py --config config.yaml --out results/dphm_compare.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time

import habit_corpus
import passages
from harness import (
    char_prefix_match,
    cut_points,
    ngram_overlap,
    trim_to_boundary,
    word_prefix_match,
)
from llama_bridge import (
    LlamaClient,
    build_completer,
    fused_generate,
    load_config,
    normalize_cut_prefix,
    parse_logprobs,
    server_ready,
    train_memory,
)
from dphm import DPHMCompleter


def _hist(vals):
    h = {}
    for v in vals:
        b = v if v <= 4 else "5+"
        h[str(b)] = h.get(str(b), 0) + 1
    return h


def _agg(key, records):
    vals = [r[key] for r in records if r.get(key) is not None]
    if not vals:
        return {}
    vals.sort()
    return {
        "mean": round(statistics.mean(vals), 1),
        "p50": round(statistics.median(vals), 1),
        "p90": round(vals[int(len(vals) * 0.9)], 1),
        "max": round(max(vals), 1),
    }


def spot_check_signoff(completer: DPHMCompleter, client: LlamaClient):
    p = normalize_cut_prefix(
        "Thanks again for putting this together.\n\nBest,\n")
    base = parse_logprobs(client.logprobs(p, n_probs=32))
    top = completer.suggest(p, k=3, base_candidates=base)
    print("[spot check] Best,\\n ->", [(s.text, s.source) for s in top], file=sys.stderr)


def run_mode_base(client: LlamaClient, prefix: str, completion_cfg: dict):
    pred, ttft, total, tim = client.complete(prefix, completion_cfg)
    return pred, ttft, total, tim, []


def run_mode_dphm(client: LlamaClient, completer: DPHMCompleter,
                  prefix: str, cfg: dict):
    pred, total, steps = fused_generate(
        client, completer, prefix, cfg["dphm"], cfg["completion"], cfg["llama_bridge"])
    ttft = (steps[0]["step_ms"] / 1000.0) if steps else total
    return pred, ttft, total, {}, steps


def run_experiment(cfg: dict, out_path: str | None = None):
    url = cfg["server"]["url"]
    if not server_ready(url):
        print(f"ERROR: llama-server not reachable at {url}", file=sys.stderr)
        sys.exit(1)

    exp = cfg["experiment"]
    completion_cfg = cfg["completion"]
    modes = exp.get("modes", ["base", "dphm"])
    text = passages.PASSAGES[exp["passage"]]
    pts = cut_points(text, exp["min_words"], exp["step_words"])

    mid = exp.get("mid_cursor", False)
    if mid:
        import re
        pts = [c for c in pts
               if len(re.findall(r"\S+", text[c:])) >= exp.get("min_suffix_words", 10)]

    client = LlamaClient(url, timeout=cfg["llama_bridge"].get("logprob_timeout_s", 120))
    completer = None
    if "dphm" in modes and cfg["dphm"].get("enabled", True):
        completer = build_completer(cfg, client)
        train_cfg = cfg.get("training", {})
        corpus_name = train_cfg.get("corpus", "default")
        if corpus_name != "none":
            sentences = habit_corpus.CORPORA.get(corpus_name, habit_corpus.DEFAULT)
            t0 = time.time()
            train_memory(completer, sentences,
                         repeats=train_cfg.get("repeats", 8),
                         flush_timeout=train_cfg.get("flush_timeout_s", 10.0))
            print(f"[cold path] trained on {len(sentences)} habits x "
                  f"{train_cfg.get('repeats', 8)} in {time.time()-t0:.2f}s; "
                  f"promoted={len(completer.lexicon.habits)}", file=sys.stderr)
        spot_check_signoff(completer, client)

    client.complete("Hello", completion_cfg)

    all_records = {m: [] for m in modes}
    for idx, c in enumerate(pts):
        prefix = text[:c]
        truth = text[c:]
        for mode in modes:
            if mode == "base":
                pred, ttft, total, tim, steps = run_mode_base(client, prefix, completion_cfg)
            else:
                pred, ttft, total, tim, steps = run_mode_dphm(client, completer, prefix, cfg)
            shown = trim_to_boundary(pred)
            rec = {
                "i": idx,
                "mode": mode,
                "prefix_chars": len(prefix),
                "prefix_tail": prefix[-50:].replace("\n", "\\n"),
                "suggestion": pred,
                "shown": shown,
                "truth_next": truth[:80].replace("\n", "\\n"),
                "ttft_ms": round(ttft * 1000, 1),
                "total_ms": round(total * 1000, 1),
                "char_match": char_prefix_match(pred, truth),
                "word_match": word_prefix_match(pred, truth),
                "fusion_steps": steps,
            }
            if tim:
                rec.update({
                    "prompt_n": tim.get("prompt_n"),
                    "prompt_ms": round(tim.get("prompt_ms", 0), 1),
                    "predicted_n": tim.get("predicted_n"),
                    "predicted_ms": round(tim.get("predicted_ms", 0), 1),
                })
            if mid:
                rec["dup_lead_words"] = rec["word_match"]
                rec["dup_ngram"] = ngram_overlap(shown or pred, truth)
                rec["collides"] = rec["dup_lead_words"] >= 1 or rec["dup_ngram"]
            all_records[mode].append(rec)
            print(
                f"[{mode:4s} {idx:2d}] ttft={rec['ttft_ms']:6.1f}ms "
                f"wmatch={rec['word_match']} shown={shown!r}",
                file=sys.stderr,
            )

    summaries = {}
    for mode, records in all_records.items():
        s = {
            "mode": mode,
            "n_requests": len(records),
            "ttft_ms": _agg("ttft_ms", records),
            "total_ms": _agg("total_ms", records),
            "word_match_mean": round(statistics.mean([r["word_match"] for r in records]), 2),
            "char_match_mean": round(statistics.mean([r["char_match"] for r in records]), 2),
            "word_match_hist": _hist([r["word_match"] for r in records]),
        }
        if mid:
            n = len(records)
            s["suffix_collision_rate"] = round(
                sum(r["collides"] for r in records) / n, 2) if n else 0.0
        summaries[mode] = s

    comparison = None
    if "base" in all_records and "dphm" in all_records:
        deltas = []
        wins = 0
        for b, d in zip(all_records["base"], all_records["dphm"]):
            delta = d["word_match"] - b["word_match"]
            deltas.append(delta)
            if delta > 0:
                wins += 1
        comparison = {
            "dphm_word_match_wins": wins,
            "n_cut_points": len(deltas),
            "mean_word_match_delta": round(statistics.mean(deltas), 2),
            "char_match_delta_mean": round(
                statistics.mean(d["char_match"] - b["char_match"]
                                for b, d in zip(all_records["base"], all_records["dphm"])), 2),
        }

    if completer:
        lat = []
        for _ in range(500):
            p = normalize_cut_prefix(text[:pts[len(pts) // 2]])
            t = time.perf_counter()
            completer.suggest(p, base_candidates=[])
            lat.append((time.perf_counter() - t) * 1000)
        lat.sort()
        comparison = comparison or {}
        comparison["dphm_hot_path_ms"] = {
            "p50": round(lat[len(lat) // 2], 3),
            "p99": round(lat[int(len(lat) * 0.99)], 3),
        }
        completer.close()

    out = {
        "label": exp.get("label", "dphm"),
        "passage": exp["passage"],
        "config_file": cfg.get("_config_path"),
        "summaries": summaries,
        "comparison": comparison,
        "records": all_records,
    }
    if out_path:
        with open(out_path, "w") as f:
            json.dump(out, f, indent=2)
    print(json.dumps({"summaries": summaries, "comparison": comparison}, indent=2))
    return out


def main():
    ap = argparse.ArgumentParser(description="DPHM + llama autocomplete harness")
    ap.add_argument("--config", default="config.yaml")
    ap.add_argument("--out", default=None)
    ap.add_argument("--passage", default=None, choices=["email", "prose"])
    ap.add_argument("--label", default=None)
    args = ap.parse_args()

    cfg = load_config(args.config)
    cfg["_config_path"] = args.config
    if args.passage:
        cfg["experiment"]["passage"] = args.passage
    if args.label:
        cfg["experiment"]["label"] = args.label
    if args.out is None:
        args.out = f"results/{cfg['experiment'].get('label', 'dphm')}.json"

    run_experiment(cfg, args.out)


if __name__ == "__main__":
    main()
