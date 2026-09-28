"""
DPHM: Dual-Path Habit Memory
============================
A low-latency memory layer for real-time text completion (autocomplete).

Design principles
-----------------
1. Hot path / cold path decoupling:
   - Hot path (`suggest`) runs on every keystroke. It only touches O(1)
     hash/trie lookups. No embeddings, no ANN, no LLM. Target p99 < 5 ms.
   - Cold path (`commit` -> background consolidator) does everything
     expensive (habit extraction, consolidation, optional LLM profiling)
     asynchronously, then *compiles* results into hot-path data structures.

2. Habit = decayed personal n-gram cache, fused with a base LM.
   Theory: Cache LM (Kuhn & De Mori 1990), Neural Cache (Grave et al. 2017,
   arXiv:1612.04426), kNN-LM interpolation (Khandelwal et al. 2020,
   arXiv:1911.00172), shallow fusion (Gulcehre et al. 2015,
   arXiv:1503.03535), Stupid Backoff (Brants et al. 2007), Ebbinghaus
   forgetting-curve consolidation (MemoryBank, arXiv:2305.10250).

3. Speculative prefetch: semantic retrieval is triggered by word
   boundaries / pauses (debounced, async), never by keystrokes. The hot
   path only *reads* the prefetch buffer (a dict lookup).

The module is dependency-free (stdlib only) so it can be embedded in an
IME, editor plugin, or web backend without a vector DB in the hot path.
"""

from __future__ import annotations

import heapq
import math
import queue
import re
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

Token = str
Context = Tuple[Token, ...]

_WORD_RE = re.compile(r"[A-Za-z0-9_\-']+|[\u4e00-\u9fff]|[^\sA-Za-z0-9\u4e00-\u9fff]")


def tokenize(text: str) -> List[Token]:
    """Lightweight bilingual tokenizer: English words stay whole,
    CJK is split per character (a subword/jieba tokenizer can be swapped in)."""
    return _WORD_RE.findall(text.lower())


# ---------------------------------------------------------------------------
# 1. Decayed n-gram trie (long-term habit LM + short-term session cache)
# ---------------------------------------------------------------------------

@dataclass
class _DecayedCount:
    """Lazily decayed counter: value(t) = value * gamma ** (t - stamp).
    Writes are O(1); decay is only materialized on read."""
    value: float = 0.0
    stamp: float = 0.0


class DecayedNGramTrie:
    """Personal n-gram model with exponential time decay and Stupid Backoff.

    - `half_life_s` controls forgetting: a pattern must *recur* to keep a
      high effective count => surviving mass encodes long-term habits
      (discrete Ebbinghaus consolidation).
    - Lookup is a chain of dict gets: O(order) per query, microseconds.
    - Memory is bounded by periodic pruning of decayed-out entries
      (cold path calls `prune`).
    """

    def __init__(self, order: int = 3, half_life_s: float = 7 * 24 * 3600.0,
                 backoff_alpha: float = 0.4):
        self.order = order
        self.log_gamma = -math.log(2.0) / half_life_s  # per-second decay
        self.backoff_alpha = backoff_alpha
        # continuations[context][next_token] -> _DecayedCount
        self.continuations: Dict[Context, Dict[Token, _DecayedCount]] = defaultdict(dict)
        # context_totals[context] -> _DecayedCount (denominator cache)
        self.context_totals: Dict[Context, _DecayedCount] = defaultdict(_DecayedCount)
        self._lock = threading.Lock()

    # -- internal ----------------------------------------------------------
    def _decayed(self, c: _DecayedCount, now: float) -> float:
        return c.value * math.exp(self.log_gamma * (now - c.stamp))

    def _bump(self, c: _DecayedCount, now: float, amount: float) -> None:
        c.value = self._decayed(c, now) + amount
        c.stamp = now

    # -- write path (called from cold path only) ---------------------------
    def observe(self, tokens: Sequence[Token], weight: float = 1.0,
                now: Optional[float] = None) -> None:
        now = time.time() if now is None else now
        with self._lock:
            for i in range(len(tokens)):
                for n in range(1, self.order + 1):
                    if i - n + 1 < 0:
                        break
                    ctx = tuple(tokens[i - n + 1:i])  # length n-1 context
                    nxt = tokens[i]
                    bucket = self.continuations[ctx]
                    cell = bucket.get(nxt)
                    if cell is None:
                        cell = bucket[nxt] = _DecayedCount()
                    self._bump(cell, now, weight)
                    self._bump(self.context_totals[ctx], now, weight)

    # -- read path (hot, lock-free reads on dicts are safe enough for
    #    suggestion ranking; strictness is not required here) --------------
    def score(self, context: Sequence[Token], candidate: Token,
              now: Optional[float] = None) -> float:
        """Stupid-Backoff log-score: S(w|c) = f(c,w)/f(c) with alpha backoff.
        Returns log score, or -inf-ish floor if never seen."""
        now = time.time() if now is None else now
        penalty = 0.0
        for start in range(max(0, len(context) - self.order + 1), len(context) + 1):
            ctx = tuple(context[start:])
            bucket = self.continuations.get(ctx)
            if bucket:
                cell = bucket.get(candidate)
                total = self.context_totals.get(ctx)
                if cell is not None and total is not None:
                    num = self._decayed(cell, now)
                    den = self._decayed(total, now)
                    if num > 1e-6 and den > 1e-6:
                        return math.log(num / den) + penalty
            penalty += math.log(self.backoff_alpha)
        return -18.0  # floor

    def top_continuations(self, context: Sequence[Token], k: int = 8,
                          prefix: str = "", now: Optional[float] = None
                          ) -> List[Tuple[Token, float]]:
        """Top-k next tokens under the longest matching context, optionally
        filtered by a typed prefix (for mid-word completion)."""
        now = time.time() if now is None else now
        for start in range(max(0, len(context) - self.order + 1), len(context) + 1):
            ctx = tuple(context[start:])
            bucket = self.continuations.get(ctx)
            if not bucket:
                continue
            total = self.context_totals.get(ctx)
            den = self._decayed(total, now) if total else 0.0
            if den <= 1e-6:
                continue
            items = []
            for tok, cell in bucket.items():
                if prefix and not tok.startswith(prefix):
                    continue
                v = self._decayed(cell, now)
                if v > 1e-4:
                    items.append((tok, math.log(v / den)))
            if items:
                return heapq.nlargest(k, items, key=lambda x: x[1])
        return []

    # -- maintenance (cold path) -------------------------------------------
    def prune(self, floor: float = 0.05, now: Optional[float] = None) -> int:
        now = time.time() if now is None else now
        removed = 0
        with self._lock:
            for ctx in list(self.continuations.keys()):
                bucket = self.continuations[ctx]
                for tok in list(bucket.keys()):
                    if self._decayed(bucket[tok], now) < floor:
                        del bucket[tok]
                        removed += 1
                if not bucket:
                    del self.continuations[ctx]
                    self.context_totals.pop(ctx, None)
        return removed


# ---------------------------------------------------------------------------
# 2. Habit lexicon: consolidated multi-token habits (phrases / templates)
# ---------------------------------------------------------------------------

@dataclass
class Habit:
    phrase: Tuple[Token, ...]
    strength: float           # consolidated (decayed) frequency
    pmi: float                # collocation cohesion
    tags: Tuple[str, ...] = ()


class HabitLexicon:
    """Long-term, human-auditable habit store. Promoted by the cold path
    when a phrase's *decayed* count and PMI both clear thresholds, i.e. the
    phrase recurs across time (consolidation), not just within one burst.

    Hot-path access: `by_prefix_token` is a dict keyed by the habit's first
    (context-matched) token -> O(1) candidate fetch."""

    def __init__(self):
        self.habits: Dict[Tuple[Token, ...], Habit] = {}
        self.by_anchor: Dict[Token, List[Habit]] = defaultdict(list)

    def promote(self, habit: Habit) -> None:
        key = habit.phrase
        old = self.habits.get(key)
        self.habits[key] = habit
        if old is None:
            self.by_anchor[key[0]].append(habit)

    def candidates_after(self, last_token: Token, max_n: int = 5) -> List[Habit]:
        return self.by_anchor.get(last_token, [])[:max_n]


# ---------------------------------------------------------------------------
# 3. Speculative prefetch buffer (semantic memory kept OFF the hot path)
# ---------------------------------------------------------------------------

class PrefetchBuffer:
    """Holds the result of the latest async semantic retrieval.
    Hot path reads it as a plain dict: token -> boost (log-space)."""

    def __init__(self):
        self._boosts: Dict[Token, float] = {}
        self._version = 0

    def publish(self, boosts: Dict[Token, float]) -> None:
        self._boosts = boosts          # atomic pointer swap in CPython
        self._version += 1

    def boost(self, token: Token) -> float:
        return self._boosts.get(token, 0.0)


class SpeculativePrefetcher:
    """Debounced background retrieval. `retrieve_fn(context_text) -> boosts`
    can be an embedding+ANN search, a style-profile lookup, or an LLM call;
    it never blocks the keystroke path."""

    def __init__(self, buffer: PrefetchBuffer,
                 retrieve_fn: Callable[[str], Dict[Token, float]],
                 debounce_s: float = 0.15):
        self.buffer = buffer
        self.retrieve_fn = retrieve_fn
        self.debounce_s = debounce_s
        self._q: "queue.Queue[str]" = queue.Queue()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def notify(self, context_text: str) -> None:
        """Call on word boundaries / pauses. Cheap: just enqueues."""
        self._q.put(context_text)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                ctx = self._q.get(timeout=0.25)
            except queue.Empty:
                continue
            # debounce: keep only the freshest context
            deadline = time.time() + self.debounce_s
            while time.time() < deadline:
                try:
                    ctx = self._q.get(timeout=max(0.0, deadline - time.time()))
                except queue.Empty:
                    break
            try:
                self.buffer.publish(self.retrieve_fn(ctx))
            except Exception:
                pass  # retrieval failures must never surface on the hot path

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)


# ---------------------------------------------------------------------------
# 4. Async consolidator (the entire write/"memory formation" pipeline)
# ---------------------------------------------------------------------------

class AsyncConsolidator:
    """Consumes committed text off a queue and:
       1) updates the long-term trie (slow decay) — 'observation'
       2) mines collocations by decayed count x PMI and promotes them
          into the HabitLexicon — 'consolidation'
       3) periodically prunes decayed entries — 'forgetting'
       4) (hook) optional LLM habit profiling via `profile_fn`
    Everything here can be arbitrarily slow without hurting typing latency."""

    def __init__(self, long_trie: DecayedNGramTrie, lexicon: HabitLexicon,
                 promote_min_count: float = 3.0, promote_min_pmi: float = 1.5,
                 profile_fn: Optional[Callable[[str], None]] = None):
        self.long_trie = long_trie
        self.lexicon = lexicon
        self.promote_min_count = promote_min_count
        self.promote_min_pmi = promote_min_pmi
        self.profile_fn = profile_fn
        self._q: "queue.Queue[Tuple[str, float]]" = queue.Queue()
        self._stop = threading.Event()
        self._pending = 0
        self._pending_lock = threading.Lock()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def submit(self, text: str, now: Optional[float] = None) -> None:
        with self._pending_lock:
            self._pending += 1
        self._q.put((text, time.time() if now is None else now))

    def flush(self, timeout: float = 5.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._pending_lock:
                if self._pending == 0:
                    return
            time.sleep(0.01)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                text, now = self._q.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                self._consolidate(text, now)
            finally:
                with self._pending_lock:
                    self._pending -= 1

    def _consolidate(self, text: str, now: float) -> None:
        tokens = tokenize(text)
        if not tokens:
            return
        self.long_trie.observe(tokens, now=now)
        self._mine_and_promote(tokens, now)
        if self.profile_fn is not None:
            self.profile_fn(text)  # e.g. LLM style profiling — fully async

    def _mine_and_promote(self, tokens: Sequence[Token], now: float) -> None:
        """Promote bigrams/trigrams whose *decayed* joint count and PMI are
        both high: recurrence over time (not burstiness) defines a habit."""
        trie = self.long_trie
        uni_total_cell = trie.context_totals.get(())
        if uni_total_cell is None:
            return
        total = trie._decayed(uni_total_cell, now)
        if total <= 1.0:
            return

        def uni_p(tok: Token) -> float:
            cell = trie.continuations.get((), {}).get(tok)
            v = trie._decayed(cell, now) if cell else 0.0
            return max(v, 1e-9) / total

        for n in (2, 3):
            for i in range(len(tokens) - n + 1):
                phrase = tuple(tokens[i:i + n])
                ctx, nxt = phrase[:-1], phrase[-1]
                cell = trie.continuations.get(ctx, {}).get(nxt)
                if cell is None:
                    continue
                joint = trie._decayed(cell, now)
                if joint < self.promote_min_count:
                    continue
                p_joint = joint / total
                p_indep = 1.0
                for t in phrase:
                    p_indep *= uni_p(t)
                pmi = math.log(p_joint / max(p_indep, 1e-12)) / (n - 1)
                if pmi >= self.promote_min_pmi:
                    self.lexicon.promote(Habit(phrase=phrase, strength=joint, pmi=pmi))

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)


# ---------------------------------------------------------------------------
# 5. The completer: hot-path shallow fusion
# ---------------------------------------------------------------------------

@dataclass
class Suggestion:
    text: str
    score: float
    source: str  # 'habit' | 'ngram' | 'base'


class DPHMCompleter:
    """Facade tying everything together.

    Hot path per keystroke:
        suggestions = completer.suggest(buffer_text)
      -> tokenizes tail, gathers candidates from (session cache, long-term
         trie, habit lexicon, base LM), ranks by shallow fusion. Dict-only.

    Integration events:
        completer.on_word_boundary(buffer_text)  # cheap; feeds prefetcher
        completer.commit(final_text)             # cheap; feeds consolidator
    """

    def __init__(self,
                 base_lm: Optional[Callable[[Sequence[Token], str], List[Tuple[Token, float]]]] = None,
                 retrieve_fn: Optional[Callable[[str], Dict[Token, float]]] = None,
                 lambda_long: float = 1.0, lambda_sess: float = 0.7,
                 lambda_base: float = 0.5, beta_prefetch: float = 0.8,
                 long_half_life_s: float = 30 * 24 * 3600.0,
                 sess_half_life_s: float = 15 * 60.0):
        self.long_trie = DecayedNGramTrie(order=3, half_life_s=long_half_life_s)
        self.sess_trie = DecayedNGramTrie(order=3, half_life_s=sess_half_life_s)
        self.lexicon = HabitLexicon()
        self.prefetch = PrefetchBuffer()
        self.prefetcher = (SpeculativePrefetcher(self.prefetch, retrieve_fn)
                           if retrieve_fn else None)
        self.consolidator = AsyncConsolidator(self.long_trie, self.lexicon)
        self.base_lm = base_lm or (lambda ctx, prefix: [])
        self.l_long, self.l_sess, self.l_base = lambda_long, lambda_sess, lambda_base
        self.beta = beta_prefetch

    # ---- events -----------------------------------------------------------
    def on_word_boundary(self, buffer_text: str) -> None:
        self.sess_trie.observe(tokenize(buffer_text)[-8:])  # tiny, in-line OK
        if self.prefetcher:
            self.prefetcher.notify(buffer_text)

    def commit(self, final_text: str) -> None:
        """User accepted/sent the text -> becomes long-term learning signal."""
        self.consolidator.submit(final_text)

    # ---- hot path ----------------------------------------------------------
    def suggest(self, buffer_text: str, k: int = 5) -> List[Suggestion]:
        now = time.time()
        trailing_space = buffer_text.endswith((" ", "\n"))
        tokens = tokenize(buffer_text)
        if trailing_space or not tokens:
            context, prefix = tuple(tokens[-4:]), ""
        else:
            context, prefix = tuple(tokens[-5:-1]), tokens[-1]

        cand: Dict[Token, Dict[str, float]] = {}

        def add(tok: Token, src: str, logp: float) -> None:
            slot = cand.setdefault(tok, {})
            slot[src] = max(slot.get(src, -1e9), logp)

        for tok, lp in self.long_trie.top_continuations(context, k=12, prefix=prefix, now=now):
            add(tok, "long", lp)
        for tok, lp in self.sess_trie.top_continuations(context, k=12, prefix=prefix, now=now):
            add(tok, "sess", lp)
        for tok, lp in self.base_lm(context, prefix):
            add(tok, "base", lp)

        # multi-token habit completion anchored on the last committed token
        habit_phrases: List[Tuple[str, float]] = []
        if context:
            for h in self.lexicon.candidates_after(context[-1]):
                rest = h.phrase[1:]
                if not rest:
                    continue
                if prefix and not rest[0].startswith(prefix):
                    continue
                habit_phrases.append((" ".join(rest),
                                      0.3 * math.log1p(h.strength) + 0.2 * h.pmi))

        results: List[Suggestion] = []
        floor = -18.0
        for tok, srcs in cand.items():
            score = (self.l_long * srcs.get("long", floor)
                     + self.l_sess * srcs.get("sess", floor)
                     + self.l_base * srcs.get("base", floor)
                     + self.beta * self.prefetch.boost(tok))
            main = max(srcs, key=srcs.get)
            results.append(Suggestion(tok, score, {"long": "ngram", "sess": "ngram",
                                                   "base": "base"}[main]))
        for phrase, s in habit_phrases:
            results.append(Suggestion(phrase, s, "habit"))

        results.sort(key=lambda s: s.score, reverse=True)
        return results[:k]

    def close(self) -> None:
        if self.prefetcher:
            self.prefetcher.close()
        self.consolidator.close()
