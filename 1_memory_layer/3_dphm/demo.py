"""
Demo & latency benchmark for DPHM (Dual-Path Habit Memory).

Simulates a bilingual user with strong long-term habits (technical English
terms embedded in Chinese, recurring templates), trains the memory via the
async cold path, then measures per-keystroke hot-path latency.
"""

import random
import statistics
import time

from dphm import DPHMCompleter, tokenize


# ---- a stub "base completion model" (replace with your real LM logits) ----
BASE_VOCAB = {
    "the": -2.0, "and": -2.2, "model": -3.0, "we": -2.5, "use": -3.1,
    "algorithm": -3.5, "regret": -4.0, "bound": -4.2, "data": -3.0,
}

def base_lm(context, prefix):
    return [(t, lp) for t, lp in BASE_VOCAB.items()
            if not prefix or t.startswith(prefix)][:8]


# ---- a stub semantic retriever for speculative prefetch -------------------
# In production: embed(context) -> ANN over style/habit memories -> boosts.
STYLE_MEMORY = {
    "email": {"best": 0.8, "regards": 0.9, "professor": 0.6},
    "paper": {"regret": 0.9, "bandit": 0.9, "theorem": 0.7},
}

def retrieve_fn(context_text):
    time.sleep(0.02)  # pretend this is a 20 ms ANN + rerank
    boosts = {}
    low = context_text.lower()
    for key, table in STYLE_MEMORY.items():
        if key in low:
            boosts.update(table)
    return boosts


# ---- simulated long-term usage corpus (the user's habits) -----------------
HABIT_SENTENCES = [
    "our OUCB algorithm achieves sublinear regret bound",
    "the regret bound of the bandit algorithm is sublinear",
    "we fine-tune the LLM with LoRA adapters",
    "我们 使用 bandit algorithm 来 优化 推荐",
    "这个 regret bound 是 sublinear 的",
    "best regards William",
    "please find attached my CV",
    "the aviation safety agent improves specificity",
] * 6  # recurrence over time is what promotes a habit


def main():
    c = DPHMCompleter(base_lm=base_lm, retrieve_fn=retrieve_fn)

    # ---- cold path: learn habits asynchronously ----
    t0 = time.time()
    for s in HABIT_SENTENCES:
        c.commit(s)
    c.consolidator.flush()
    print(f"[cold path] consolidated {len(HABIT_SENTENCES)} texts "
          f"in {time.time()-t0:.3f}s (async, off the typing path)")
    print(f"[cold path] promoted habits: {len(c.lexicon.habits)}")
    sample = sorted(c.lexicon.habits.values(), key=lambda h: -h.strength)[:6]
    for h in sample:
        print(f"    habit={' '.join(h.phrase):32s} strength={h.strength:6.1f} pmi={h.pmi:.2f}")

    # ---- qualitative check ----
    print("\n[suggest] 'the regret ' ->",
          [(s.text, s.source, round(s.score, 2)) for s in c.suggest("the regret ")])
    print("[suggest] 'our OUCB al' ->",
          [(s.text, s.source, round(s.score, 2)) for s in c.suggest("our OUCB al")])
    print("[suggest] '这个 regret ' ->",
          [(s.text, s.source, round(s.score, 2)) for s in c.suggest("这个 regret ")])

    # speculative prefetch demo: notify on a pause, then suggest
    c.on_word_boundary("Subject: paper draft. the ")
    time.sleep(0.3)  # background retrieval completes while user "thinks"
    print("[suggest+prefetch] after 'paper' context ->",
          [(s.text, s.source, round(s.score, 2)) for s in c.suggest("the re")])

    # ---- latency benchmark: hot path only ----
    prefixes = ["the ", "our OUCB ", "we fine", "这个 ", "regret b",
                "please find ", "best re", "bandit al"]
    lat = []
    for _ in range(3000):
        p = random.choice(prefixes)
        t = time.perf_counter()
        c.suggest(p)
        lat.append((time.perf_counter() - t) * 1000)
    lat.sort()
    print(f"\n[hot path latency over {len(lat)} keystrokes]"
          f"\n  p50 = {statistics.median(lat):.3f} ms"
          f"\n  p95 = {lat[int(0.95*len(lat))]:.3f} ms"
          f"\n  p99 = {lat[int(0.99*len(lat))]:.3f} ms"
          f"\n  max = {lat[-1]:.3f} ms")

    c.close()


if __name__ == "__main__":
    main()
