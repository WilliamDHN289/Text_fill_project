"""Response-level evaluation with a frozen local model served by ollama.

All benchmark queries of the primary corpus go through every arm and every
model with greedy decoding. Each prompt starts with a random request id, so the server
cannot reuse a cached prefix and TTFT always includes a full prefill. For each (arm, query) we log the prompt-level outcome of the
block, the block length, retrieval latency, time to first token, and the
judged completion. A second pass times retrieval while a generation is
running on the same machine.

Judge (normalized containment, allowing the respellings of
`benchmark.value_pattern`; for a cancelled chain any form of "cancel"):
  correct  current value, no superseded or other-person value
  mixed    current value together with a superseded or other-person value
  stale    superseded value without the current one
  wrong    other-person value without current or superseded values
  other    none of the above
"""

from __future__ import annotations

import json
import random
import re
import subprocess
import threading
import time
import urllib.request

import arms as A
import benchmark as B
import common as C
import metrics as M

OLLAMA = "http://127.0.0.1:11434"
PROMPT = ("[request {nonce}]\nYou are helping the user write a message to {partner}. Continue the unfinished "
          "message with only the words that come next.\n\n{instruction}{memory}"
          "Unfinished message to {partner}:\n{prefix}")
LATEST = ("Memory lines are dated. If two lines give different values for the same "
          "thing, use the most recent one.\n\n")


def _post(path: str, payload: dict, timeout: float):
    req = urllib.request.Request(OLLAMA + path, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def generate(model: str, prompt: str, num_predict: int, timeout: float,
             temperature: float = 0.0, seed: int = 0) -> dict:
    payload = {"model": model, "prompt": prompt, "stream": True, "keep_alive": "30m",
               "options": {"temperature": temperature, "seed": seed,
                           "num_predict": num_predict}}
    t0, ttft, parts, final = time.perf_counter(), None, [], {}
    with _post("/api/generate", payload, timeout) as resp:
        for line in resp:
            ev = json.loads(line)
            if ev.get("response") and ttft is None:
                ttft = (time.perf_counter() - t0) * 1e3
            parts.append(ev.get("response", ""))
            if ev.get("done"):
                final = ev
                break
    return {"text": "".join(parts).strip(), "ttft_ms": ttft,
            "prompt_tokens": final.get("prompt_eval_count"),
            "prefill_ms": (final.get("prompt_eval_duration") or 0) / 1e6}


def judge(text: str, labels: dict) -> str:
    """labels: {"current": str, "stale": [str], "wrong": [str]}, as logged per row.
    A query with no answer has `current` None: there the correct completion is
    one that states no value of the queried type, which `wrong` collects."""
    stale = any(B.mentions(text, v) for v in labels["stale"])
    wrong = any(B.mentions(text, v) for v in labels["wrong"])
    if labels["current"] is None:
        return "wrong" if wrong else "stale" if stale else "correct"
    cur = ("cancel" in B.canon(text) if labels["current"] == "cancelled"
           else B.mentions(text, labels["current"]))
    if cur:
        return "mixed" if stale or wrong else "correct"
    return "stale" if stale else "wrong" if wrong else "other"


def backend_info(model: str) -> dict:
    with _post("/api/show", {"model": model}, 10) as resp:
        details = json.loads(resp.read()).get("details", {})
    ps = subprocess.run(["ollama", "ps"], capture_output=True, text=True).stdout
    version = subprocess.run(["ollama", "--version"], capture_output=True, text=True).stdout
    return {"model": model, "details": details, "ollama_ps": ps, "ollama_version": version.strip()}


def retrieval_during_generation(cfg, model, arms, bench, n) -> dict:
    r = cfg["pfm"]["retrieval"]
    rng = random.Random(0)
    queries = [rng.choice(bench.queries) for _ in range(n)]

    out = {}
    for arm in arms:
        idle = [A.serve(arm, q.prefix, [q.partner], B.BASE, r["k"], r["budget"])[2]
                for q in queries]
        busy, done = [], threading.Event()

        def loop():
            while not done.is_set():
                generate(model, "Write a long story about a lighthouse.", 256, 300)

        t = threading.Thread(target=loop, daemon=True)
        t.start()
        time.sleep(2.0)                                   # generation is under way
        for q in queries:
            busy.append(A.serve(arm, q.prefix, [q.partner], B.BASE, r["k"], r["budget"])[2])
        done.set()
        t.join()
        out[arm.name] = {cond: {f"p{p}": M.percentile(v, p) for p in (50, 95, 99)}
                         for cond, v in (("idle", idle), ("during_generation", busy))}
    return out


def slice_conditions(cfg: dict):
    """(name, bench, {arm name: arm}) for the conditions that break the main
    benchmark's assumptions, so the response level is measured where the
    prompt is wrong rather than only where it is right."""
    import extractor as X
    import identity as I
    import slices as S
    lcfg, seed = cfg["llm"], cfg["benchmark"]["seeds"][0]
    base = C.make_bench(cfg, seed, lcfg["corpus"])
    p, q = lcfg["slices"]["key_noise"]
    out = []

    noisy = C.build_store(cfg["pfm"], base, noise=(p, q, seed))
    out.append((f"key noise p={p} q={q}", base, {"pfm": A.PFMArm(noisy, "pfm")}))

    shuffled = S.reorder(base, lcfg["slices"]["reorder"], seed)
    out.append((f"out of order {lcfg['slices']['reorder']}", shuffled,
                {"pfm": A.PFMArm(C.build_store(cfg["pfm"], shuffled), "pfm")}))

    hard = S.hard_identity(cfg["slices"]["hard_pairs"], seed)
    hs = C.build_store(cfg["pfm"], hard)
    pa = A.PFMArm(hs)
    out.append(("hard identity", hard,
                {"pfm": pa,
                 "pfm_identity": I.IdentityArm(pa, hs, hard=True),
                 "pfm_identity_abstain": I.SlotAbstain(I.IdentityArm(pa, hs, hard=True), hs)}))
    return out


def slice_rows(cfg: dict, nonces) -> list:
    """Response level on the slice conditions, for every model."""
    lcfg, r = cfg["llm"], cfg["pfm"]["retrieval"]
    rows = []
    for model in lcfg["models"]:
        for name, bench, arms in slice_conditions(cfg):
            for arm_name, arm in arms.items():
                for q in bench.queries:
                    block, _, ms = A.serve(arm, q.prefix, [q.partner], B.BASE,
                                           r["k"], r["budget"])
                    prompt = PROMPT.format(nonce=nonces.getrandbits(32), partner=q.partner,
                                           prefix=q.prefix, instruction="",
                                           memory=block + "\n\n" if block else "")
                    g = generate(model, prompt, lcfg["num_predict"], lcfg["timeout_s"])
                    rows.append(M.row(q, arm=arm_name, model=model, condition=name,
                                      **M.outcome(block, q), retrieval_ms=ms,
                                      completion=g["text"],
                                      verdict=judge(g["text"], {"current": q.current,
                                                                "stale": q.stale,
                                                                "wrong": q.wrong}),
                                      ttft_ms=g["ttft_ms"], prompt_tokens=g["prompt_tokens"],
                                      prefill_ms=g["prefill_ms"]))
            print(f"  llm slice {model} / {name} done", flush=True)
    return rows


def sampling_check(cfg: dict, nonces) -> list:
    """The main comparison repeated with sampling, to show the prompt-level
    gap is not an artefact of one greedy decode."""
    lcfg, r = cfg["llm"], cfg["pfm"]["retrieval"]
    scfg = lcfg["sampling_check"]
    bench = C.make_bench(cfg, cfg["benchmark"]["seeds"][0], lcfg["corpus"])
    keyed = C.build_store(cfg["pfm"], bench)
    arms = {"pfm": A.PFMArm(keyed),
            "pfm_keyless": A.PFMArm(C.build_store(cfg["pfm"], bench, keyed=False),
                                    "pfm_keyless")}
    rows = []
    for dseed in scfg["seeds"]:
        for name, arm in arms.items():
            for q in bench.queries:
                block, _, _ = A.serve(arm, q.prefix, [q.partner], B.BASE, r["k"], r["budget"])
                prompt = PROMPT.format(nonce=nonces.getrandbits(32), partner=q.partner,
                                       prefix=q.prefix, instruction="",
                                       memory=block + "\n\n" if block else "")
                g = generate(scfg["model"], prompt, lcfg["num_predict"], lcfg["timeout_s"],
                             scfg["temperature"], dseed)
                rows.append(M.row(q, arm=name, model=scfg["model"], condition="sampling",
                                  decode_seed=dseed, temperature=scfg["temperature"],
                                  **M.outcome(block, q), completion=g["text"],
                                  verdict=judge(g["text"], {"current": q.current,
                                                            "stale": q.stale,
                                                            "wrong": q.wrong})))
        print(f"  llm sampling seed {dseed} done", flush=True)
    return rows


def run(cfg: dict, out) -> dict:
    lcfg, r = cfg["llm"], cfg["pfm"]["retrieval"]
    bench = C.make_bench(cfg, cfg["benchmark"]["seeds"][0], lcfg["corpus"])
    keyed = C.build_store(cfg["pfm"], bench)
    arm_by_name = {"pfm": A.PFMArm(keyed),
                   "pfm_keyless": A.PFMArm(C.build_store(cfg["pfm"], bench, keyed=False),
                                           "pfm_keyless"),
                   "bm25": A.BM25Arm(keyed), "bm25_validity": A.BM25Arm(keyed, valid_only=True)}
    arm_by_name["bm25_latest"] = arm_by_name["bm25"]
    if "dense_validity" in lcfg["arms"]:
        encoder = A.Encoder(cfg["dense"])
        arm_by_name["dense_validity"] = A.DenseArm(keyed, encoder, valid_only=True)

    nonces = random.Random(0)             # a unique first line rules out prefix-cache reuse
    rows, backends = [], {}
    for model in lcfg["models"]:
        generate(model, "Hello", 1, lcfg["timeout_s"])    # load weights before timing
        for name in lcfg["arms"]:
            for q in bench.queries:
                block, ranked, ms = ("", [], 0.0) if name == "none" else A.serve(
                    arm_by_name[name], q.prefix, [q.partner], B.BASE, r["k"], r["budget"])
                prompt = PROMPT.format(nonce=nonces.getrandbits(32), partner=q.partner,
                                       prefix=q.prefix,
                                       instruction=LATEST if name == "bm25_latest" else "",
                                       memory=block + "\n\n" if block else "")
                g = generate(model, prompt, lcfg["num_predict"], lcfg["timeout_s"])
                rows.append(M.row(q, arm=name, model=model, **M.outcome(block, q),
                                  retrieval_ms=ms, completion=g["text"],
                                  verdict=judge(g["text"], {"current": q.current,
                                                            "stale": q.stale, "wrong": q.wrong}),
                                  ttft_ms=g["ttft_ms"], prompt_tokens=g["prompt_tokens"],
                                  prefill_ms=g["prefill_ms"]))
            print(f"  llm {model} arm {name} done", flush=True)
        backends[model] = backend_info(model)
    if lcfg.get("slices"):
        rows += slice_rows(cfg, nonces)
    if lcfg.get("sampling_check"):
        rows += sampling_check(cfg, nonces)
    kept = [r for r in M.read_jsonl(out / "llm.jsonl")            # keep other models' rows
            if (out / "llm.jsonl").exists() and r.get("model") not in lcfg["models"]] \
        if (out / "llm.jsonl").exists() else []
    M.write_jsonl(out / "llm.jsonl", kept + rows)
    if (out / "llm.json").exists():
        backends = {**json.loads((out / "llm.json").read_text()).get("backend", {}), **backends}

    info = {"backend": backends, "decoding": {"temperature": 0, "seed": 0,
                                              "num_predict": lcfg["num_predict"]},
            "prompt": PROMPT, "latest_instruction": LATEST,
            "retrieval_during_generation": retrieval_during_generation(
                cfg, lcfg["models"][0], [arm_by_name["pfm"],
                                         arm_by_name.get("dense_validity", arm_by_name["bm25"])],
                bench, lcfg["retrieval_during_generation"])}
    C.write_json(out / "llm.json", info)
    return info
