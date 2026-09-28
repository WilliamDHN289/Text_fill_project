#!/usr/bin/env python3
"""Long-term user simulation: does DPHM memory help autocomplete over weeks?

Replays a real person's writing history (public data: one Enron author's
emails + Gutenberg prose, see fetch_corpus.py) as N daily sessions. Each
session is *test-then-train* (prequential):

  1. EVALUATE  — at sampled cut points, predict the next word two ways
                 from the SAME llama logprobs call:
                   base = llama.cpp candidates alone
                   dphm = the same candidates shallow-fused with memory
  2. TRAIN     — commit the session's texts to DPHM's cold path (the
                 consolidator mines/promotes habits, decay forgets old ones)

A virtual clock advances one day per session so the Ebbinghaus-style decay
(30-day long half-life, 15-min session half-life) actually matters.

After every session it prints the intermediate state — accuracy, memory
size, newly promoted habits, top recurring phrases ("常用文本"), fixed probe
prefixes' suggestions, and example wins/losses — so you can watch the
memory learn. Full records go to a JSON for visualize.py.

Usage:
  ./run_server.sh models/gemma-4-E2B-base-Q4_K_M.gguf 99 &
  python3 simulate_longterm.py --config config.yaml --out results/longterm_sim.json
  python3 simulate_longterm.py --no-llm --sessions 8      # quick smoke test
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time

from dphm import DPHMCompleter, tokenize
from llama_bridge import (
    LlamaClient,
    load_config,
    make_retrieve_fn,
    normalize_cut_prefix,
    parse_logprobs,
    server_ready,
)

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "data", "user_corpus.json")
DAY_S = 86400.0
_WORDISH = re.compile(r"[a-z0-9']+")

# Fixed probe prefixes, checked against pure memory (no LLM) every session.
# Their suggestions changing over sessions is the visible trace of learning.
PROBES = [
    "Let me know if you ",
    "I think we ",
    "Please give me a call if ",
    "We will continue to ",
    "in my opinion she ",
    "It is a truth universally ",
]


def norm_word(s: str) -> str:
    m = _WORDISH.search(s.lower())
    return m.group(0) if m else ""


def word_spans(text: str):
    return [(m.start(), m.group(0)) for m in re.finditer(r"\S+", text)]


def pick_cut_points(spans, n_pts: int, min_word: int = 5, max_word: int = 120):
    """Evenly spaced word indices whose word is a real word (not punctuation)."""
    hi = min(len(spans) - 1, max_word)
    if hi <= min_word:
        return []
    idxs, step = [], max(1, (hi - min_word) // max(1, n_pts))
    for i in range(min_word, hi, step):
        if len(norm_word(spans[i][1])) >= 2:
            idxs.append(i)
        if len(idxs) >= n_pts:
            break
    return idxs


def saved_chars(suggestion: str, truth_words) -> int:
    """Chars the user would not have to type if she accepted the suggestion."""
    sug = [norm_word(w) for w in suggestion.split()]
    saved = matched = 0
    for s, t in zip(sug, truth_words):
        if not s or s != norm_word(t):
            break
        saved += len(t)
        matched += 1
    return saved + max(0, matched - 1)  # + accepted spaces


def build_sessions(corpus: dict, n_sessions: int, emails_per: int, prose_per: int):
    """Interleave the chronological email stream with book paragraphs."""
    emails = corpus["email"]
    prose = corpus["prose"]
    sessions, ei, pi = [], 0, 0
    for _ in range(n_sessions):
        texts = []
        for _ in range(emails_per):
            if ei < len(emails):
                texts.append(("email", emails[ei]["text"]))
                ei += 1
        for _ in range(prose_per):
            if pi < len(prose):
                texts.append(("prose", prose[pi]))
                pi += 1
        if texts:
            sessions.append(texts)
    return sessions


def evaluate_text(client, completer, register, text, vnow, cfg, rec_sink):
    """Simulate typing `text` word by word; at sampled cut points score
    base vs dphm next-word prediction. Returns per-point records."""
    spans = word_spans(text)
    cuts = set(pick_cut_points(spans, cfg["pts_per_text"]))
    n_probs = cfg["n_probs"]
    for i, (off, _w) in enumerate(spans):
        prefix = text[:off]
        if not prefix.strip():
            continue
        buf = normalize_cut_prefix(prefix.rstrip())
        # user reached a word boundary -> feed the (cheap) session path
        completer.on_word_boundary(buf, now=vnow)
        if i not in cuts:
            continue

        truth_words = [w for (_o, w) in spans[i:i + 6]]
        truth = norm_word(truth_words[0])
        if not truth:
            continue

        base_cands, llama_ms = [], None
        if client is not None:
            # llama gets the prefix without the trailing space: Gemma tokens
            # carry their own leading space; a dangling " " derails the model
            t0 = time.perf_counter()
            base_cands = parse_logprobs(
                client.logprobs(prefix.rstrip(), n_probs=n_probs))
            llama_ms = (time.perf_counter() - t0) * 1000

        t0 = time.perf_counter()
        picks = completer.suggest(buf, k=5, base_candidates=base_cands, now=vnow)
        dphm_ms = (time.perf_counter() - t0) * 1000

        base_top = [w for w, _ in base_cands[:3]]
        dphm_top = [norm_word(p.text.split()[0]) for p in picks[:3] if p.text.split()]
        rec = {
            "register": register,
            "prefix_tail": prefix[-45:].replace("\n", "\\n"),
            "truth": truth,
            "base_top3": base_top,
            "dphm_top3": [(p.text, p.source, round(p.score, 2)) for p in picks[:3]],
            "base_top1_hit": bool(base_top and base_top[0] == truth),
            "base_top3_hit": truth in base_top,
            "dphm_top1_hit": bool(dphm_top and dphm_top[0] == truth),
            "dphm_top3_hit": truth in dphm_top,
            "base_saved": saved_chars(base_top[0], truth_words) if base_top else 0,
            "dphm_saved": saved_chars(picks[0].text, truth_words) if picks else 0,
            "dphm_top1_source": picks[0].source if picks else None,
            "llama_ms": round(llama_ms, 1) if llama_ms is not None else None,
            "dphm_ms": round(dphm_ms, 3),
        }
        rec_sink.append(rec)


def pct(records, key):
    return round(100 * sum(r[key] for r in records) / len(records), 1) if records else 0.0


def p(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * q))]


def top_habits(completer, k=8):
    hs = sorted(completer.lexicon.habits.values(),
                key=lambda h: -h.strength)[:k]
    return [(" ".join(h.phrase), round(h.strength, 1)) for h in hs]


def run(args):
    cfg = load_config(args.config)
    lt = cfg.get("longterm", {})
    n_sessions = args.sessions or lt.get("sessions", 30)
    sim_cfg = {
        "pts_per_text": lt.get("pts_per_text", 4),
        "n_probs": cfg["llama_bridge"].get("n_probs", 64),
    }

    with open(CORPUS) as f:
        corpus = json.load(f)
    sessions = build_sessions(corpus, n_sessions,
                              lt.get("emails_per_session", 5),
                              lt.get("prose_per_session", 2))

    client = None
    if not args.no_llm:
        url = cfg["server"]["url"]
        if not server_ready(url, tries=10):
            print(f"ERROR: llama-server not reachable at {url} "
                  f"(use --no-llm for a memory-only dry run)", file=sys.stderr)
            sys.exit(1)
        client = LlamaClient(url, timeout=cfg["llama_bridge"].get("logprob_timeout_s", 120))
        client.logprobs("Hello", n_probs=8)  # warm up

    retrieve_fn = make_retrieve_fn(cfg["prefetch_memory"]) if cfg.get("prefetch_memory") else None
    completer = DPHMCompleter.from_config(cfg["dphm"], retrieve_fn=retrieve_fn)

    t0 = time.time()
    session_rows, all_records = [], []
    cum_saved = {"base": 0, "dphm": 0}
    known_habits: set = set()

    for si, texts in enumerate(sessions):
        vnow = t0 + si * DAY_S
        recs: list = []
        for register, text in texts:
            evaluate_text(client, completer, register, text, vnow, sim_cfg, recs)

        # ---- train (cold path) on what the user "sent" this session -------
        for _register, text in texts:
            completer.commit(text, now=vnow)
        completer.consolidator.flush(timeout=15.0)
        pruned = completer.long_trie.prune(floor=0.05, now=vnow) if si % 5 == 4 else 0

        new_habits = [h for h in completer.lexicon.habits if h not in known_habits]
        known_habits.update(new_habits)

        # ---- probes: pure-memory suggestions on fixed prefixes ------------
        probes = {}
        for probe in PROBES:
            picks = completer.suggest(probe, k=3, base_candidates=[], now=vnow)
            probes[probe] = [(s.text, s.source, round(s.score, 2)) for s in picks]

        # ---- summarize -----------------------------------------------------
        for m in ("base", "dphm"):
            cum_saved[m] += sum(r[f"{m}_saved"] for r in recs)
        emails_n = sum(1 for reg, _ in texts if reg == "email")
        row = {
            "session": si, "day": si,
            "n_texts": len(texts), "n_emails": emails_n,
            "n_points": len(recs),
            "base_top1": pct(recs, "base_top1_hit"), "base_top3": pct(recs, "base_top3_hit"),
            "dphm_top1": pct(recs, "dphm_top1_hit"), "dphm_top3": pct(recs, "dphm_top3_hit"),
            "email_base_top1": pct([r for r in recs if r["register"] == "email"], "base_top1_hit"),
            "email_dphm_top1": pct([r for r in recs if r["register"] == "email"], "dphm_top1_hit"),
            "prose_base_top1": pct([r for r in recs if r["register"] == "prose"], "base_top1_hit"),
            "prose_dphm_top1": pct([r for r in recs if r["register"] == "prose"], "dphm_top1_hit"),
            "base_saved": sum(r["base_saved"] for r in recs),
            "dphm_saved": sum(r["dphm_saved"] for r in recs),
            "cum_base_saved": cum_saved["base"], "cum_dphm_saved": cum_saved["dphm"],
            "trie_contexts": len(completer.long_trie.continuations),
            "habits": len(completer.lexicon.habits),
            "new_habits": len(new_habits), "pruned": pruned,
            "top_habits": top_habits(completer),
            "llama_ms_p50": p([r["llama_ms"] for r in recs if r["llama_ms"]], 0.5),
            "dphm_ms_p50": round(p([r["dphm_ms"] for r in recs], 0.5) or 0, 3),
            "dphm_ms_p99": round(p([r["dphm_ms"] for r in recs], 0.99) or 0, 3),
            "probes": probes,
        }
        session_rows.append(row)
        for r in recs:
            r["session"] = si
        all_records.extend(recs)

        # ---- human-readable intermediate dump ------------------------------
        print(f"\n{'=' * 74}")
        print(f" Session {si + 1:02d}/{len(sessions)}  (day {si})   "
              f"{emails_n} emails + {len(texts) - emails_n} prose   "
              f"{len(recs)} eval points")
        print(f"{'-' * 74}")
        d1 = row["dphm_top1"] - row["base_top1"]
        print(f" next-word top-1   base {row['base_top1']:5.1f}%   "
              f"dphm {row['dphm_top1']:5.1f}%   (Δ {d1:+.1f}pp)")
        print(f" next-word top-3   base {row['base_top3']:5.1f}%   "
              f"dphm {row['dphm_top3']:5.1f}%")
        print(f" keystrokes saved  base {row['base_saved']:3d} ch   "
              f"dphm {row['dphm_saved']:3d} ch   "
              f"(cumulative {cum_saved['base']} vs {cum_saved['dphm']})")
        lm = f"{row['llama_ms_p50']:.0f}" if row["llama_ms_p50"] else "--"
        print(f" latency           llama p50 {lm} ms   "
              f"dphm hot-path p50 {row['dphm_ms_p50']:.3f} ms  "
              f"p99 {row['dphm_ms_p99']:.3f} ms")
        print(f" memory            {row['trie_contexts']:,} trie contexts | "
              f"{row['habits']} habits (+{row['new_habits']} new"
              + (f", pruned {pruned}" if pruned else "") + ")")
        if row["top_habits"]:
            shown = " | ".join(f"\"{ph}\" {s}" for ph, s in row["top_habits"][:5])
            print(f" top habits        {shown}")
        for probe, picks in probes.items():
            if picks:
                s = "  ".join(f"{t!r}({src},{sc})" for t, src, sc in picks)
                print(f" probe {probe!r:<32} -> {s}")
        wins = [r for r in recs if r["dphm_top1_hit"] and not r["base_top1_hit"]]
        losses = [r for r in recs if r["base_top1_hit"] and not r["dphm_top1_hit"]]
        for r in wins[:2]:
            print(f" [dphm win ] …{r['prefix_tail']}| truth={r['truth']!r} "
                  f"dphm={r['dphm_top3'][0][0]!r}({r['dphm_top3'][0][1]}) "
                  f"base={r['base_top3'][0] if r['base_top3'] else None!r}")
        for r in losses[:1]:
            print(f" [base win ] …{r['prefix_tail']}| truth={r['truth']!r} "
                  f"base={r['base_top3'][0]!r} "
                  f"dphm={r['dphm_top3'][0][0] if r['dphm_top3'] else None!r}")
        sys.stdout.flush()

    completer.close()

    # ---- overall summary ----------------------------------------------------
    half = len(all_records) // 2
    overall = {
        "n_sessions": len(sessions), "n_points": len(all_records),
        "base_top1": pct(all_records, "base_top1_hit"),
        "dphm_top1": pct(all_records, "dphm_top1_hit"),
        "base_top3": pct(all_records, "base_top3_hit"),
        "dphm_top3": pct(all_records, "dphm_top3_hit"),
        "first_half": {"base_top1": pct(all_records[:half], "base_top1_hit"),
                       "dphm_top1": pct(all_records[:half], "dphm_top1_hit")},
        "second_half": {"base_top1": pct(all_records[half:], "base_top1_hit"),
                        "dphm_top1": pct(all_records[half:], "dphm_top1_hit")},
        "cum_saved": cum_saved,
        "dphm_ms_p99": round(p([r["dphm_ms"] for r in all_records], 0.99) or 0, 3),
        "llama_ms_p50": p([r["llama_ms"] for r in all_records if r["llama_ms"]], 0.5),
    }
    out = {
        "label": "longterm_sim" + ("_nollm" if args.no_llm else ""),
        "no_llm": args.no_llm,
        "corpus_meta": corpus.get("meta", {}),
        "probes": PROBES,
        "overall": overall,
        "sessions": session_rows,
        "records": all_records,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1)

    print(f"\n{'=' * 74}")
    print(" OVERALL", json.dumps(overall, indent=2))
    print(f" -> {args.out}")
    return out


def main():
    ap = argparse.ArgumentParser(description="Long-term DPHM user simulation")
    ap.add_argument("--config", default=os.path.join(HERE, "config.yaml"))
    ap.add_argument("--sessions", type=int, default=None)
    ap.add_argument("--out", default=os.path.join(HERE, "results", "longterm_sim.json"))
    ap.add_argument("--no-llm", action="store_true",
                    help="skip llama-server; memory-only dry run")
    args = ap.parse_args()
    run(args)


if __name__ == "__main__":
    main()
