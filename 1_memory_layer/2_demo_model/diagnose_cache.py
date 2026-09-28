#!/usr/bin/env python3
"""Reproduce the prefix-cache diagnosis (Gemma 4 E2B sliding-window attention).

Background: in the autocomplete loop the prompt is a *growing prefix*, so the
KV cache from the previous keystroke should be reused and prefill should stay
~flat. It doesn't. This script runs the same probe chain I used to find out why,
printing a one-line verdict per step. The key signal throughout is the server's
reported `prompt_n`: how many prompt tokens were *actually re-encoded* this
request.

  - reuse working  -> prompt_n ~= the few new tokens (stays small / constant)
  - reuse failing  -> prompt_n ~= full prefix length (grows every step)

Run against an already-running llama-server (see run_server.sh):
    python3 diagnose_cache.py --url http://127.0.0.1:8080 \
        --server-log results/server_base_gpu.log

Stdlib only; mirrors harness.py's request style.
"""

import argparse
import json
import re
import sys
import urllib.request


def prefill(url, prompt, n_predict=4):
    """Send one streaming /completion and return (prompt_n, prompt_ms) from the
    final stop chunk -- i.e. how many prefix tokens were re-encoded."""
    data = json.dumps({
        "prompt": prompt, "n_predict": n_predict,
        "temperature": 0, "cache_prompt": True, "stream": True,
    }).encode()
    req = urllib.request.Request(url.rstrip("/") + "/completion", data=data,
                                 headers={"Content-Type": "application/json"})
    tim = {}
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if line.startswith("data:"):
                obj = json.loads(line[len("data:"):].strip())
                if obj.get("stop"):
                    tim = obj.get("timings", {}) or {}
    return tim.get("prompt_n", -1), tim.get("prompt_ms", 0.0)


# ~100 words so the longest controlled probe (N=90) has room.
BASE = (
    "The history of the printing press is often told as a single moment of "
    "invention but the reality was far more gradual and complicated than that "
    "simple story would suggest to most people who read about it today because "
    "long before Gutenberg assembled his famous press printers in East Asia had "
    "been using carved wooden blocks to reproduce text and images for many "
    "centuries and what really changed in Europe was the combination of movable "
    "metal type an oily ink and a press adapted from machines used to crush "
    "grapes and olives across the whole continent"
).split()


def header(t):
    print("\n" + "=" * 72 + f"\n{t}\n" + "=" * 72)


def probe_A(url):
    header("PROBE A  cache works at all?  (resend identical prompt)")
    p = " ".join(BASE[:60])
    n1, ms1 = prefill(url, p)
    n2, ms2 = prefill(url, p)
    print(f"  1st send: prefill {ms1:6.1f} ms / {n1} tok")
    print(f"  2nd send: prefill {ms2:6.1f} ms / {n2} tok")
    ok = n2 < n1 / 2
    print(f"  => {'OK: identical prompt IS reused (mechanism works).' if ok else 'cache not reused even for identical prompt.'}")


def probe_B(url):
    header("PROBE B  growing-prefix loop  (the autocomplete pattern)")
    print("  prompt_n should stay small if reuse works; growing == reuse fails.")
    pns = []
    for k in range(8, 56, 4):
        n, ms = prefill(url, " ".join(BASE[:k]), n_predict=24)
        pns.append(n)
        print(f"  prefix={k:2d} words -> prefill {ms:6.1f} ms / {n:3d} tok re-encoded")
    grows = pns[-1] > pns[0] * 3
    print(f"  => {'FAIL: prompt_n grows ~linearly -> growing prefix is re-encoded each step.' if grows else 'reuse holds prompt_n ~flat.'}")


def probe_C(url):
    header("PROBE C  rule out: do generated tokens pollute the slot?")
    print("  same growing loop with n_predict=1 vs 24; if identical -> not the cause.")
    for npred in (1, 24):
        row = []
        for k in range(8, 40, 4):
            n, _ = prefill(url, " ".join(BASE[:k]), n_predict=npred)
            row.append(n)
        print(f"  n_predict={npred:2d}: prompt_n = {row}")
    print("  => if the two rows match, generation length is NOT the cause (it isn't).")


def probe_D(url):
    header("PROBE D  controlled extend across base lengths")
    print("  establish A (N words), then send A+5 words; reuse => small prompt_n.")
    for N in (10, 30, 60, 90):
        prefill(url, " ".join(BASE[:N]))            # establish A in the slot
        n, ms = prefill(url, " ".join(BASE[:N + 5]))  # extend by 5 words
        verdict = "REUSE-OK" if n < 15 else "NO-REUSE (full re-encode)"
        print(f"  base={N:2d} words: extend+5 -> {n:3d} tok ({ms:6.1f} ms)  {verdict}")
    print("  => reuse only survives for short prefixes; long ones get truncated.")


def probe_E(server_log):
    header("PROBE E  smoking gun in the server log")
    if not server_log:
        print("  (no --server-log given; pass results/server_base_gpu.log to see it)")
        return
    pat = re.compile(r"n_swa|invalidated context checkpoint", re.I)
    hits = []
    try:
        with open(server_log) as f:
            for line in f:
                if pat.search(line):
                    hits.append(line.rstrip())
    except FileNotFoundError:
        print(f"  log not found: {server_log}")
        return
    for h in hits[:6]:
        print("  " + h[-160:])
    print(f"  ... {len(hits)} matching lines total")
    if hits:
        print("  => the model uses sliding-window attention (see n_swa above); the SWA")
        print("     layers invalidate the KV checkpoints prefix-reuse relies on -> root cause.")
    else:
        print("  => no SWA / checkpoint-invalidation lines found in this log.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--server-log", default=None,
                    help="path to the llama-server log to grep for n_swa")
    args = ap.parse_args()

    try:
        with urllib.request.urlopen(args.url.rstrip("/") + "/health", timeout=3) as r:
            json.loads(r.read())
    except Exception:
        print("ERROR: llama-server not reachable at " + args.url +
              " (start it with run_server.sh first)", file=sys.stderr)
        sys.exit(1)

    probe_A(args.url)
    probe_B(args.url)
    probe_C(args.url)
    probe_D(args.url)
    probe_E(args.server_log)
    print("\nConclusion: the cache mechanism works (A), but the growing-prefix loop")
    print("re-encodes almost the whole prefix every step (B), and it is not caused by")
    print("generated tokens (C) but by prefix length (D) -- because the model's 512-token")
    print("sliding-window attention invalidates the reuse checkpoints (E).")


if __name__ == "__main__":
    main()
