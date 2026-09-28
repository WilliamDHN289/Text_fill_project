#!/usr/bin/env python3
"""Local autocomplete harness for llama.cpp (gemma-4-E2B).

Drives a Smart-Compose-style completion loop against a running `llama-server`:
walk through a realistic passage, and at a series of cut points hand the model
the text-so-far and ask for the continuation. Measure latency (with a streaming
request so we capture time-to-first-token) and suggestion quality, then dump
per-request records + an aggregate summary.

Talks to the server's native /completion endpoint (stdlib only, no pip installs).

Latency, in this loop, splits into two parts the server reports separately:
  - prompt eval (prefill): processing the prefix tokens (or just the *new*
    tokens when prefix caching is on).
  - generation (decode): producing the suggestion tokens one at a time.
Time-to-first-token (TTFT) ~= prefill + first decode step, and it is what
determines whether the suggestion "feels instant".

Accuracy here is measured automatically against the passage's own continuation:
how many leading tokens/chars of the suggestion match the text the author
actually wrote next. That is a *lower bound* on quality (many continuations are
valid), so we also dump the raw suggestions for human judgement.
"""

import argparse
import json
import re
import statistics
import sys
import time
import urllib.request


# ----------------------------- server I/O -----------------------------------

def post_stream(base_url, payload, timeout=120):
    """POST to /completion with stream=true. Returns (full_text, ttft_s,
    total_s, server_timings_dict). TTFT = wall-clock to first non-empty token."""
    payload = dict(payload, stream=True)
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        base_url.rstrip("/") + "/completion",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft = None
    chunks = []
    timings = {}
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line or not line.startswith("data:"):
                continue
            obj = json.loads(line[len("data:"):].strip())
            piece = obj.get("content", "")
            if piece:
                if ttft is None:
                    ttft = time.perf_counter() - t0
                chunks.append(piece)
            if obj.get("stop"):
                timings = obj.get("timings", {}) or {}
    total = time.perf_counter() - t0
    if ttft is None:          # model emitted no tokens at all
        ttft = total
    return "".join(chunks), ttft, total, timings


def server_ready(base_url, tries=240, delay=0.5):
    for _ in range(tries):
        try:
            with urllib.request.urlopen(base_url.rstrip("/") + "/health", timeout=2) as r:
                if json.loads(r.read()).get("status") == "ok":
                    return True
        except Exception:
            pass
        time.sleep(delay)
    return False


# --------------------------- cut points & metrics ---------------------------

def cut_points(text, min_words=6, step_words=8):
    """Word-boundary cut points so prefixes grow like real typing. Returns a
    list of character offsets, each at the end of a word."""
    # offsets at the end of each word
    ends = [m.end() for m in re.finditer(r"\S+", text)]
    pts = []
    i = min_words
    while i < len(ends):
        pts.append(ends[i])
        i += step_words
    return pts


_WS = re.compile(r"\s+")

def _norm(s):
    return _WS.sub(" ", s.strip().lower())

def char_prefix_match(pred, truth):
    """Length of the longest common prefix (normalized) divided over truth."""
    a, b = _norm(pred), _norm(truth)
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n

def word_prefix_match(pred, truth):
    """How many leading whole words of the suggestion match what came next."""
    a = _norm(pred).split(" ")
    b = _norm(truth).split(" ")
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def ngram_overlap(pred, suffix, n=3, window_chars=120):
    """True if any n-word gram of the suggestion appears verbatim inside the
    start of the suffix. In mid-cursor mode the suffix is text the author has
    *already written to the right of the cursor*, so an overlap means the model
    re-suggested text that is already there — the duplication/run-on failure a
    left-to-right causal model produces because it cannot see the suffix."""
    a = _norm(pred).split(" ")
    b = _norm(suffix[:window_chars])
    if len(a) < n or not b:
        return False
    return any(" ".join(a[i:i + n]) in b for i in range(len(a) - n + 1))


# --------------------------------- run --------------------------------------

def trim_to_boundary(text):
    """A real UI would show one clause/sentence, not a wall of text. Trim the
    suggestion at the first newline or sentence end for the 'displayed' form."""
    nl = text.find("\n")
    if nl != -1:
        text = text[:nl]
    m = re.search(r"[.!?]\s", text)
    if m:
        text = text[: m.end() - 1]
    return text.strip()


def run(args):
    import passages
    text = passages.PASSAGES[args.passage]
    pts = cut_points(text, args.min_words, args.step_words)

    # Mid-cursor mode: simulate the user having gone back to edit *inside* the
    # text, so there is already-written content on both sides of the cursor.
    # The model still only receives the prefix (a causal LM cannot condition on
    # the suffix); we keep only cut points that leave a non-trivial suffix to
    # the right, and then measure how often the suggestion collides with it.
    mid = args.mid_cursor
    if mid:
        def suffix_words(c):
            return len(re.findall(r"\S+", text[c:]))
        pts = [c for c in pts if suffix_words(c) >= args.min_suffix_words]

    sampling = {
        "n_predict": args.n_predict,
        "temperature": args.temp,
        "top_k": args.top_k,
        "top_p": args.top_p,
        "min_p": args.min_p,
        "cache_prompt": not args.no_cache,
        # stop generating once the suggestion runs past a sentence/paragraph
        "stop": ["\n\n"] if args.stop_para else [],
    }

    records = []
    # Warm the server once (compile Metal kernels etc.) so cut-point #1 isn't
    # penalised by one-time startup costs; this mirrors a warmed app.
    post_stream(args.url, dict(sampling, prompt="Hello", n_predict=4))

    for idx, c in enumerate(pts):
        prefix = text[:c]
        truth = text[c:]
        pred, ttft, total, tim = post_stream(args.url, dict(sampling, prompt=prefix))
        shown = trim_to_boundary(pred)
        rec = {
            "i": idx,
            "prefix_chars": len(prefix),
            "prefix_tail": prefix[-50:].replace("\n", "\\n"),
            "suggestion": pred,
            "shown": shown,
            "truth_next": truth[:80].replace("\n", "\\n"),
            "ttft_ms": round(ttft * 1000, 1),
            "total_ms": round(total * 1000, 1),
            "prompt_n": tim.get("prompt_n"),
            "prompt_ms": round(tim.get("prompt_ms", 0), 1),
            "predicted_n": tim.get("predicted_n"),
            "predicted_ms": round(tim.get("predicted_ms", 0), 1),
            "char_match": char_prefix_match(pred, truth),
            "word_match": word_prefix_match(pred, truth),
        }
        if mid:
            # In mid-cursor mode `truth` is the suffix that already exists to the
            # right of the cursor. Overlap with it is the *failure* signal: the
            # model duplicates / runs into text the author already wrote.
            rec["dup_lead_words"] = rec["word_match"]
            rec["dup_ngram"] = ngram_overlap(shown or pred, truth)
            rec["collides"] = rec["dup_lead_words"] >= 1 or rec["dup_ngram"]
        records.append(rec)
        if mid:
            print(
                f"[{idx:2d}] ttft={rec['ttft_ms']:6.1f}ms "
                f"dup_lead_words={rec['dup_lead_words']} "
                f"dup_ngram={int(rec['dup_ngram'])} collides={int(rec['collides'])} "
                f"| shown={shown!r}",
                file=sys.stderr,
            )
        else:
            print(
                f"[{idx:2d}] ttft={rec['ttft_ms']:6.1f}ms total={rec['total_ms']:7.1f}ms "
                f"prefill={rec['prompt_ms']:6.1f}ms/{rec['prompt_n']}tok "
                f"gen={rec['predicted_ms']:6.1f}ms/{rec['predicted_n']}tok "
                f"wmatch={rec['word_match']}",
                file=sys.stderr,
            )

    def agg(key):
        vals = [r[key] for r in records if r[key] is not None]
        vals.sort()
        return {
            "mean": round(statistics.mean(vals), 1),
            "p50": round(statistics.median(vals), 1),
            "p90": round(vals[int(len(vals) * 0.9)], 1) if vals else None,
            "max": round(max(vals), 1),
        }

    config = {k: sampling[k] for k in
              ["n_predict", "temperature", "top_k", "top_p", "min_p",
               "cache_prompt", "stop"]}
    config["mid_cursor"] = mid
    summary = {
        "label": args.label,
        "passage": args.passage,
        "mode": "mid_cursor" if mid else "end_of_text",
        "n_requests": len(records),
        "config": config,
        "ttft_ms": agg("ttft_ms"),
        "total_ms": agg("total_ms"),
        "prompt_ms": agg("prompt_ms"),
        "predicted_ms": agg("predicted_ms"),
        "mean_prompt_tokens": round(
            statistics.mean([r["prompt_n"] for r in records if r["prompt_n"]]), 1),
        "mean_gen_tokens": round(
            statistics.mean([r["predicted_n"] for r in records if r["predicted_n"]]), 1),
        "word_match_mean": round(
            statistics.mean([r["word_match"] for r in records]), 2),
        "char_match_mean": round(
            statistics.mean([r["char_match"] for r in records]), 2),
        "word_match_hist": _hist([r["word_match"] for r in records]),
    }
    if mid:
        # Mid-cursor headline metrics: how often / how badly the suggestion
        # collides with the already-written suffix. High values are the
        # empirical signature of "the causal model ignores everything after
        # the cursor" (see WRITEUP.md Q4).
        n = len(records)
        summary["suffix_dup_lead_words_mean"] = round(
            statistics.mean([r["dup_lead_words"] for r in records]), 2)
        summary["suffix_collision_rate"] = round(
            sum(r["collides"] for r in records) / n, 2) if n else 0.0
        summary["suffix_ngram_dup_rate"] = round(
            sum(r["dup_ngram"] for r in records) / n, 2) if n else 0.0

    out = {"summary": summary, "records": records}
    if args.out:
        with open(args.out, "w") as f:
            json.dump(out, f, indent=2)
    print(json.dumps(summary, indent=2))
    return out


def _hist(vals):
    h = {}
    for v in vals:
        b = v if v <= 4 else "5+"
        h[str(b)] = h.get(str(b), 0) + 1
    return h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--label", default="run")
    ap.add_argument("--passage", default="email", choices=["email", "prose"])
    ap.add_argument("--n-predict", type=int, default=24)
    ap.add_argument("--temp", type=float, default=0.0)      # 0 == greedy
    ap.add_argument("--top-k", type=int, default=40)
    ap.add_argument("--top-p", type=float, default=0.95)
    ap.add_argument("--min-p", type=float, default=0.05)
    ap.add_argument("--min-words", type=int, default=6)
    ap.add_argument("--step-words", type=int, default=8)
    ap.add_argument("--no-cache", action="store_true",
                    help="disable server prefix KV-cache reuse (cold prefill every time)")
    ap.add_argument("--stop-para", action="store_true",
                    help="stop generation at a blank line (paragraph break)")
    ap.add_argument("--mid-cursor", action="store_true",
                    help="simulate the cursor *inside* the text (edit-in-the-middle): "
                         "still send only the prefix, but score the suggestion for "
                         "collision with the already-written suffix")
    ap.add_argument("--min-suffix-words", type=int, default=10,
                    help="mid-cursor: keep only cut points leaving at least this "
                         "many words of suffix to the right of the cursor")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if not server_ready(args.url):
        print("ERROR: llama-server not reachable at " + args.url, file=sys.stderr)
        sys.exit(1)
    run(args)


if __name__ == "__main__":
    main()
