"""Study 7 — Frozen-LLM end-to-end replay (paper task 4).

For a stratified sample of benchmark queries, run a real local model (via
ollama) on the same prompt the assistant would assemble — typing context
plus each arm's retrieved memory block — and judge the *generated*
completion, not just the prompt:

  correct       completion contains the current value
  stale         no current value, but a superseded one
  wrong_person  no current value, but another same-first-name person's value
  other         none of the above (guess / refusal / unrelated)

Also reports TTFT (time to first streamed token) and generation throughput.
The model is frozen: temperature 0, no fine-tuning, identical decoding
across arms. SKIPPED (with reason) when no ollama server/model is present.
"""

from __future__ import annotations

import json
import random
import statistics
import subprocess
import time
import urllib.request
from typing import Dict, List, Optional

import benchmark as B
import common
import keyed_extractor as KE
import retrievers as R

OLLAMA = "http://127.0.0.1:11434"

PROMPT_TPL = (
    "You are the autocomplete engine of a messaging app. Continue the "
    "user's unfinished message with ONLY the missing words. No quotes, no "
    "explanation.\n\n{memory}"
    "User is writing to {partner}. Unfinished message:\n"
    "{prefix}"
)


def _http(path: str, payload: Optional[dict] = None, timeout: float = 5.0):
    req = urllib.request.Request(
        OLLAMA + path,
        data=json.dumps(payload).encode() if payload else None,
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def _ensure_server(log) -> bool:
    try:
        _http("/api/tags")
        return True
    except Exception:
        pass
    log.append("ollama server not running; attempting `ollama serve`")
    try:
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        log.append("ollama binary not found")
        return False
    for _ in range(25):
        time.sleep(1.0)
        try:
            _http("/api/tags")
            return True
        except Exception:
            continue
    log.append("server did not come up within 25s")
    return False


def _pick_model(prefs: List[str], log) -> Optional[str]:
    with _http("/api/tags") as resp:
        tags = [m["name"] for m in json.loads(resp.read()).get("models", [])]
    log.append(f"available models: {tags}")
    for p in prefs:
        for t in tags:
            if t == p or t.startswith(p.split(":")[0]):
                return t
    return tags[0] if tags else None


def _generate(model: str, prompt: str, num_predict: int,
              timeout_s: float) -> Dict:
    payload = {"model": model, "prompt": prompt, "stream": True,
               "options": {"temperature": 0.0, "num_predict": num_predict}}
    t0 = time.perf_counter()
    ttft = None
    text = []
    with _http("/api/generate", payload, timeout=timeout_s) as resp:
        for line in resp:
            ev = json.loads(line)
            if ev.get("response"):
                if ttft is None:
                    ttft = (time.perf_counter() - t0) * 1000.0
                text.append(ev["response"])
            if ev.get("done"):
                break
    return {"text": "".join(text).strip(),
            "ttft_ms": round(ttft or 0.0, 1),
            "total_ms": round((time.perf_counter() - t0) * 1000.0, 1)}


def judge(completion: str, q: B.Query) -> str:
    if B.contains(completion, q.current):
        return "correct"
    if any(B.contains(completion, v) for v in q.stale):
        return "stale"
    if any(B.contains(completion, v) for v in q.wrong):
        return "wrong_person"
    return "other"


def _sample_queries(bench: B.Bench, n: int, rng: random.Random) -> List[B.Query]:
    hard = [q for q in bench.queries
            if q.meta["revisions"] >= 1 or q.meta["ambiguous"]]
    easy = [q for q in bench.queries if q not in hard]
    rng.shuffle(hard)
    rng.shuffle(easy)
    take = hard[:int(n * 0.75)] + easy[:n - int(n * 0.75)]
    rng.shuffle(take)
    return take[:n]


def run(cfg: dict, out_dir) -> dict:
    s7, s5 = cfg["study7"], cfg["study5"]
    log: List[str] = []
    if not _ensure_server(log):
        result = {"status": "SKIPPED",
                  "reason": "no local ollama server available", "log": log}
        common.write_json(out_dir / "study7.json", result)
        return result
    model = _pick_model(s7["model_prefs"], log)
    if model is None:
        result = {"status": "SKIPPED",
                  "reason": "ollama running but no model pulled", "log": log}
        common.write_json(out_dir / "study7.json", result)
        return result

    bench = B.generate(s5["n_chains"], s5["seed"],
                       s5["corpora"][s7["corpus"]], s5["p_cancel"],
                       {int(k): v for k, v in s5["rev_weights"].items()},
                       s7["corpus"])
    dcfg = dict(cfg["dpfm"], extraction={"gazetteer": bench.gazetteer})
    mem = common.build_memory(dcfg, bench.messages,
                              extractor=KE.make_keyed_extractor(bench.gazetteer),
                              cls=common.TemporalDPFM)
    retr_names = [a for a in s7["arms"] if a != "off"]
    arms, _ = R.build_arms(retr_names, mem, cfg)
    arms_by = {a.name: a for a in arms}

    rng = random.Random(s5["seed"] + 1)
    queries = _sample_queries(bench, s7["n_queries"], rng)
    k = cfg["dpfm"]["retrieval"]["k"]
    budget = cfg["dpfm"]["retrieval"]["prompt_char_budget"]

    per_arm: Dict[str, dict] = {}
    transcripts = []
    for arm_name in s7["arms"]:
        outcomes = {"correct": 0, "stale": 0, "wrong_person": 0, "other": 0}
        ttfts, totals = [], []
        for qi, q in enumerate(queries):
            if arm_name == "off":
                memory = ""
            else:
                block, _ = arms_by[arm_name].retrieve(
                    q.prefix, q.partner, k, budget, common.BASE)
                memory = block + "\n\n" if block else ""
            prompt = PROMPT_TPL.format(memory=memory, partner=q.partner,
                                       prefix=q.prefix)
            try:
                g = _generate(model, prompt, s7["num_predict"],
                              s7["timeout_s"])
            except Exception as e:
                g = {"text": f"<ERROR {type(e).__name__}>", "ttft_ms": 0.0,
                     "total_ms": 0.0}
            verdict = judge(g["text"], q)
            outcomes[verdict] += 1
            if g["ttft_ms"] > 0:
                ttfts.append(g["ttft_ms"])
                totals.append(g["total_ms"])
            if qi < 6:
                transcripts.append({"arm": arm_name, "prefix": q.prefix,
                                    "partner": q.partner,
                                    "current": q.current,
                                    "completion": g["text"][:160],
                                    "verdict": verdict})
        n = len(queries)
        per_arm[arm_name] = {
            "outcomes": outcomes,
            "rates": {kk: {"rate": round(v / n, 4),
                           "ci": [round(x, 4) for x in B.wilson(v, n)[1:]]}
                      for kk, v in outcomes.items()},
            "ttft_ms": {"p50": round(statistics.median(ttfts), 1) if ttfts else None,
                        "p95": round(sorted(ttfts)[int(0.95 * (len(ttfts) - 1))], 1)
                               if ttfts else None},
            "total_ms_p50": round(statistics.median(totals), 1) if totals else None,
        }

    result = {"status": "DONE", "model": model, "n_queries": len(queries),
              "corpus": s7["corpus"], "arms": per_arm,
              "sample_transcripts": transcripts, "log": log,
              "decoding": {"temperature": 0.0,
                           "num_predict": s7["num_predict"]}}
    common.write_json(out_dir / "study7.json", result)
    return result


def summarize(r: dict) -> str:
    if r.get("status") != "DONE":
        return f"Study 7: {r.get('status')} ({r.get('reason', '')})"
    lines = [f"Study 7 (frozen LLM = {r['model']}, {r['n_queries']} queries):"]
    for name, d in r["arms"].items():
        o = d["rates"]
        lines.append(
            f"  {name:12s} correct {o['correct']['rate']:.3f} "
            f"stale {o['stale']['rate']:.3f} "
            f"wrong-person {o['wrong_person']['rate']:.3f} "
            f"other {o['other']['rate']:.3f} "
            f"TTFT p50={d['ttft_ms']['p50']}ms")
    return "\n".join(lines)
