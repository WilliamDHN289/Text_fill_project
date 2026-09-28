"""Bridge llama-server logprobs into DPHM shallow fusion."""

from __future__ import annotations

import json
import re
import time
import urllib.request
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from dphm import DPHMCompleter, Suggestion, tokenize

Token = str
_WORDISH = re.compile(r"[a-z0-9]+", re.I)


def load_config(path: str) -> dict:
    import yaml
    with open(path) as f:
        return yaml.safe_load(f)


def server_ready(base_url: str, tries: int = 240, delay: float = 0.5) -> bool:
    for _ in range(tries):
        try:
            with urllib.request.urlopen(base_url.rstrip("/") + "/health", timeout=2) as r:
                if json.loads(r.read()).get("status") == "ok":
                    return True
        except Exception:
            pass
        time.sleep(delay)
    return False


def normalize_cut_prefix(prefix: str) -> str:
    """Cut points land at word ends without a trailing space; DPHM expects
    word-boundary context for next-word prediction."""
    if not prefix:
        return prefix
    if prefix[-1].isspace():
        return prefix
    if prefix[-1] in ".,!?;:":
        return prefix + " "
    return prefix + " "


def llama_token_to_word(tok: str) -> str:
    s = tok.strip().lower()
    if not s:
        return ""
    m = _WORDISH.search(s)
    return m.group(0) if m else ""


class LlamaClient:
    def __init__(self, base_url: str, timeout: float = 120.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def logprobs(self, prompt: str, n_probs: int = 64,
                 temperature: float = 0.0) -> List[dict]:
        payload = {
            "prompt": prompt,
            "n_predict": 1,
            "n_probs": n_probs,
            "temperature": temperature,
            "stream": False,
        }
        req = urllib.request.Request(
            self.base_url + "/completion",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            obj = json.loads(resp.read())
        return obj.get("completion_probabilities") or []

    def complete(self, prompt: str, cfg: Mapping[str, Any]) -> Tuple[str, float, float, dict]:
        payload = {
            "prompt": prompt,
            "stream": True,
            "n_predict": cfg["n_predict"],
            "temperature": cfg["temperature"],
            "top_k": cfg["top_k"],
            "top_p": cfg["top_p"],
            "min_p": cfg["min_p"],
            "cache_prompt": cfg.get("cache_prompt", True),
            "stop": ["\n\n"] if cfg.get("stop_para") else [],
        }
        req = urllib.request.Request(
            self.base_url + "/completion",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        t0 = time.perf_counter()
        ttft = None
        chunks: List[str] = []
        timings: dict = {}
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
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
        if ttft is None:
            ttft = total
        return "".join(chunks), ttft, total, timings


def parse_logprobs(probs: List[dict], typed_prefix: str = "") -> List[Tuple[Token, float]]:
    if not probs:
        return []
    best: Dict[Token, float] = {}
    for item in probs[0].get("top_logprobs", []):
        word = llama_token_to_word(item.get("token", ""))
        if not word:
            continue
        if typed_prefix and not word.startswith(typed_prefix.lower()):
            continue
        lp = float(item.get("logprob", -1e9))
        best[word] = max(best.get(word, -1e9), lp)
    return sorted(best.items(), key=lambda x: x[1], reverse=True)


def make_base_lm(client: LlamaClient, bridge_cfg: Mapping[str, Any],
                 completion_cfg: Mapping[str, Any]):
    n_probs = bridge_cfg.get("n_probs", 64)
    temp = completion_cfg.get("temperature", 0.0)

    def base_lm(buffer_text: str, _context: Sequence[Token], prefix: str
                ) -> List[Tuple[Token, float]]:
        return parse_logprobs(
            client.logprobs(buffer_text, n_probs=n_probs, temperature=temp), prefix)

    return base_lm


def make_retrieve_fn(prefetch_memory: Mapping[str, Mapping[str, float]],
                     simulate_latency_ms: float = 0.0):
    def retrieve(context_text: str) -> Dict[Token, float]:
        if simulate_latency_ms > 0:
            time.sleep(simulate_latency_ms / 1000.0)
        boosts: Dict[Token, float] = {}
        low = context_text.lower()
        for keyword, table in prefetch_memory.items():
            if keyword in low:
                boosts.update(table)
        return boosts

    return retrieve


def build_completer(cfg: dict, client: LlamaClient) -> DPHMCompleter:
    dphm_cfg = cfg["dphm"]
    base_lm = make_base_lm(client, cfg["llama_bridge"], cfg["completion"])
    retrieve_fn = None
    if cfg.get("prefetch_memory"):
        retrieve_fn = make_retrieve_fn(cfg["prefetch_memory"])
    return DPHMCompleter.from_config(dphm_cfg, base_lm=base_lm, retrieve_fn=retrieve_fn)


def train_memory(completer: DPHMCompleter, sentences: Sequence[str],
                 repeats: int = 1, flush_timeout: float = 10.0) -> None:
    for _ in range(repeats):
        for s in sentences:
            completer.commit(s)
    completer.consolidator.flush(timeout=flush_timeout)


def _typed_prefix(buffer: str) -> str:
    if buffer.endswith((" ", "\n")):
        return ""
    tokens = tokenize(buffer)
    return tokens[-1] if tokens else ""


def _append_suggestion(buffer: str, suggestion: Suggestion) -> str:
    text = suggestion.text.strip()
    if not text:
        return buffer
    if buffer.endswith((" ", "\n")) or not tokenize(buffer):
        if buffer.endswith("\n"):
            return buffer + text
        if buffer and not buffer.endswith(" "):
            return buffer + " " + text
        return buffer + text
    # mid-word: replace partial token
    partial = tokenize(buffer)[-1]
    raw = buffer.rstrip()
    if raw.lower().endswith(partial):
        raw = raw[: -len(partial)]
    return raw + text


def fused_generate(client: LlamaClient, completer: DPHMCompleter,
                   prefix: str, dphm_cfg: Mapping[str, Any],
                   completion_cfg: Mapping[str, Any],
                   bridge_cfg: Mapping[str, Any]) -> Tuple[str, float, List[dict]]:
    """Fuse the first N words with DPHM, then let llama finish the suggestion."""
    buffer = normalize_cut_prefix(prefix)
    max_words = dphm_cfg.get("fusion_max_words", 3)
    n_probs = bridge_cfg.get("n_probs", 64)
    temp = completion_cfg.get("temperature", 0.0)
    steps: List[dict] = []
    t0 = time.perf_counter()

    completer.on_word_boundary(buffer)
    for _ in range(max_words):
        t_step = time.perf_counter()
        typed = _typed_prefix(buffer)
        base_cands = parse_logprobs(
            client.logprobs(buffer, n_probs=n_probs, temperature=temp), typed)
        picks = completer.suggest(
            buffer, k=1, base_candidates=base_cands or None)
        if not picks:
            break
        pick = picks[0]
        min_score = dphm_cfg.get("fusion_min_score", -2.0)
        if pick.score < min_score:
            break
        if len(pick.text) <= 2 and pick.source != "habit":
            break
        new_buffer = _append_suggestion(buffer, pick)
        if new_buffer == buffer:
            break
        steps.append({
            "word": pick.text,
            "source": pick.source,
            "score": round(pick.score, 3),
            "step_ms": round((time.perf_counter() - t_step) * 1000, 1),
        })
        buffer = new_buffer
        completer.on_word_boundary(buffer)

    rest, _, _, _ = client.complete(buffer, completion_cfg)
    total = time.perf_counter() - t0
    return buffer[len(prefix):] + rest, total, steps
