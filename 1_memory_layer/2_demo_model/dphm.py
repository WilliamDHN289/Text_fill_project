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
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

Token = str
Context = Tuple[Token, ...]
BaseLMFn = Callable[[str, Sequence[Token], str], List[Tuple[Token, float]]]

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
                          ) -> Tuple[List[Tuple[Token, float]], float]:
        """Top-k next tokens under the longest matching context, optionally
        filtered by a typed prefix (for mid-word completion).

        Returns (items, evidence): items are (token, log p(token|context));
        evidence is the decayed observation mass of the matched context, so
        callers can shrink trust in probabilities estimated from little data."""
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
                return heapq.nlargest(k, items, key=lambda x: x[1]), den
        return [], 0.0

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

    def matching(self, context: Sequence[Token], max_n: int = 8) -> List[Habit]:
        """Habits whose full prefix (all tokens but the last) matches context tail."""
        if not context:
            return []
        out: List[Habit] = []
        for habit in self.habits.values():
            prefix = habit.phrase[:-1]
            if not prefix or len(context) < len(prefix):
                continue
            if tuple(context[-len(prefix):]) == prefix:
                out.append(habit)
        out.sort(key=lambda h: (-h.strength, -h.pmi))
        return out[:max_n]


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
                 promote_min_count: float = 3.0, promote_min_pmi: float = 4.0,
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
                    # skip fragile habits anchored on punctuation-only prefixes
                    prefix = phrase[:-1]
                    if prefix and all(len(t) <= 1 for t in prefix):
                        continue
                    # a habit must complete with a real word, not punctuation
                    if not any(ch.isalnum() for ch in nxt):
                        continue
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
                 base_lm: Optional[BaseLMFn] = None,
                 retrieve_fn: Optional[Callable[[str], Dict[Token, float]]] = None,
                 lambda_long: float = 1.0, lambda_sess: float = 0.7,
                 lambda_base: float = 0.5, beta_prefetch: float = 0.8,
                 long_half_life_s: float = 30 * 24 * 3600.0,
                 sess_half_life_s: float = 15 * 60.0,
                 ngram_order: int = 3, backoff_alpha: float = 0.4,
                 promote_min_count: float = 3.0, promote_min_pmi: float = 4.0,
                 prefetch_debounce_s: float = 0.15):
        self.long_trie = DecayedNGramTrie(
            order=ngram_order, half_life_s=long_half_life_s, backoff_alpha=backoff_alpha)
        self.sess_trie = DecayedNGramTrie(
            order=ngram_order, half_life_s=sess_half_life_s, backoff_alpha=backoff_alpha)
        self.lexicon = HabitLexicon()
        self.prefetch = PrefetchBuffer()
        self.prefetcher = (SpeculativePrefetcher(
            self.prefetch, retrieve_fn, debounce_s=prefetch_debounce_s)
                           if retrieve_fn else None)
        self.consolidator = AsyncConsolidator(
            self.long_trie, self.lexicon,
            promote_min_count=promote_min_count, promote_min_pmi=promote_min_pmi)
        self.base_lm = base_lm or (lambda _buf, _ctx, _prefix: [])
        self.l_long, self.l_sess, self.l_base = lambda_long, lambda_sess, lambda_base
        self.beta = beta_prefetch

    @classmethod
    def from_config(cls, cfg: Mapping[str, Any],
                    base_lm: Optional[BaseLMFn] = None,
                    retrieve_fn: Optional[Callable[[str], Dict[Token, float]]] = None
                    ) -> "DPHMCompleter":
        """Build from the `dphm:` section of config.yaml."""
        keys = (
            "lambda_long", "lambda_sess", "lambda_base", "beta_prefetch",
            "long_half_life_s", "sess_half_life_s", "ngram_order", "backoff_alpha",
            "promote_min_count", "promote_min_pmi", "prefetch_debounce_s",
        )
        kw = {k: cfg[k] for k in keys if k in cfg}
        return cls(base_lm=base_lm, retrieve_fn=retrieve_fn, **kw)

    # ---- events -----------------------------------------------------------
    def on_word_boundary(self, buffer_text: str,
                         now: Optional[float] = None) -> None:
        self.sess_trie.observe(tokenize(buffer_text)[-8:], now=now)  # tiny, in-line OK
        if self.prefetcher:
            self.prefetcher.notify(buffer_text)

    def commit(self, final_text: str, now: Optional[float] = None) -> None:
        """User accepted/sent the text -> becomes long-term learning signal.
        `now` allows simulated (virtual) clocks in offline experiments."""
        self.consolidator.submit(final_text, now=now)

    # ---- hot path ----------------------------------------------------------
    def suggest(self, buffer_text: str, k: int = 5,
                base_candidates: Optional[List[Tuple[Token, float]]] = None,
                now: Optional[float] = None) -> List[Suggestion]:
        now = time.time() if now is None else now
        trailing_space = buffer_text.endswith((" ", "\n"))
        tokens = tokenize(buffer_text)
        if trailing_space or not tokens:
            context, prefix = tuple(tokens[-4:]), ""
        else:
            context, prefix = tuple(tokens[-5:-1]), tokens[-1]

        # ---- linear interpolation in probability space (cache-LM / kNN-LM
        # style): P(w) = sum_src w_src * r_src * p_src(w). A source that has
        # not seen the context contributes 0 -- it must not *penalize*
        # candidates it merely doesn't know (the old additive-floor fusion
        # let a barely-seen session bigram outrank the base LM's top pick).
        # r_src = n/(n+tau) shrinks trust in probabilities estimated from
        # only a few (decayed) observations.
        long_items, long_ev = self.long_trie.top_continuations(
            context, k=12, prefix=prefix, now=now)
        sess_items, sess_ev = self.sess_trie.top_continuations(
            context, k=12, prefix=prefix, now=now)
        if base_candidates is not None:
            base_items = base_candidates
        else:
            base_items = self.base_lm(buffer_text, context, prefix)

        tau = 6.0
        w_total = self.l_long + self.l_sess + self.l_base
        w_long = self.l_long / w_total * (long_ev / (long_ev + tau))
        w_sess = self.l_sess / w_total * (sess_ev / (sess_ev + tau))
        w_base = self.l_base / w_total

        # confidence gate: when the base LM is already sure (a peaked
        # distribution), personal memory stays quiet; when the base LM is
        # flat -- names, phone lists, personal boilerplate -- memory speaks.
        # (Fixed lambdas measured on the long-term sim: 52% memory share
        # flips 1/3 of picks and loses 2:1; 21% barely fires. The gate is
        # the classic adaptive-interpolation fix.)
        if base_items:
            p_bmax = max(math.exp(lp) for _t, lp in base_items)
            gate = 1.0 - min(p_bmax, 0.95)
            w_long *= gate
            w_sess *= gate

        mix: Dict[Token, float] = defaultdict(float)
        main_src: Dict[Token, Tuple[float, str]] = {}

        def add(items, w: float, src: str, punct_damp: bool = False) -> None:
            if not items or w <= 0.0:
                return
            for tok, lp in items:
                p = w * math.exp(lp)
                if punct_damp and context and context[-1] in ".,!?;:":
                    p *= 0.02  # suppress spurious ". X" bigram artifacts
                mix[tok] += p
                if tok not in main_src or p > main_src[tok][0]:
                    main_src[tok] = (p, src)

        add(long_items, w_long, "ngram", punct_damp=True)
        add(sess_items, w_sess, "ngram")
        add(base_items, w_base, "base")

        results: List[Suggestion] = []
        for tok, p in mix.items():
            score = math.log(p + 1e-12) + self.beta * self.prefetch.boost(tok)
            results.append(Suggestion(tok, score, main_src[tok][1]))

        # multi-token habits: require full phrase prefix match (not anchor-only).
        # A habit does NOT get its own score scale (that would let generic
        # collocations steamroll the base LM); it must already be a mixture
        # candidate and merely receives a consolidation nudge, so it wins
        # ties -- and brings its remaining tokens along -- rather than always.
        for h in self.lexicon.matching(context):
            rest = h.phrase[-1]  # matched prefix == phrase[:-1], one token left
            if prefix and not rest.startswith(prefix):
                continue
            p = mix.get(rest)
            if p is None:
                continue
            score = math.log(p + 1e-12) + self.beta * self.prefetch.boost(rest) + 0.25
            results.append(Suggestion(rest, score, "habit"))

        results.sort(key=lambda s: s.score, reverse=True)
        seen: set = set()
        deduped = []
        for s in results:
            head = s.text.split()[0] if s.text.split() else s.text
            if head in seen:
                continue
            seen.add(head)
            deduped.append(s)
        return deduped[:k]

    def close(self) -> None:
        if self.prefetcher:
            self.prefetcher.close()
        self.consolidator.close()
