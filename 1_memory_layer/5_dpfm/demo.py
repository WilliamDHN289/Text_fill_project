"""DPFM end-to-end demo + latency benchmark.

    python3 demo.py

Sections:
  1. Ingest a small personal corpus (emails, EN + zh) via the cold path.
  2. Retrieve for a live typing context -> prompt block.
  3. Slot supersede: deadline changes, old fact is invalidated.
  4. Feedback loop: mark_used lifts a fact's rank.
  5. Parallel modes: prefetch snapshot + deadline race.
  6. Latency benchmark on a 20k-fact synthetic store.
"""

import random
import string
import time

from dpfm import (DualPathFactMemory, FactDraft, make_rule_extractor)


def hr(title: str) -> None:
    print(f"\n{'=' * 64}\n{title}\n{'=' * 64}")


def show(snap) -> None:
    print(f"  latency={snap.latency_ms:.3f} ms  stale={snap.stale}  "
          f"query_terms={list(snap.query_terms)[:8]}")
    print("  " + "\n  ".join(snap.prompt_block.splitlines()) if snap.prompt_block
          else "  (no memory hit)")


# ---------------------------------------------------------------------------
hr("1. Ingest personal corpus (cold path, async)")

mem = DualPathFactMemory(
    extractor=make_rule_extractor(gazetteer=["凤凰计划", "验收会", "王琳"]),
    prefetch_debounce_s=0.05,
)

t = time.time()
DAY = 86400.0

mem.observe_document(
    "email:001", participants=["alice@acme.com"], now=t - 20 * DAY, text=(
        "Hi Alice, quick update. The Phoenix launch is scheduled for Aug 15. "
        "Bob will own the QA signoff. I sent the revised budget of 40000 USD "
        "to Finance yesterday."))
mem.observe_document(
    "email:002", participants=["bob@acme.com"], now=t - 12 * DAY, text=(
        "Bob, the staging cluster migration is due Jul 20. "
        "Carol confirmed the vendor contract with Nimbus Cloud was signed. "
        "The retro meeting moved to Friday."))
mem.observe_document(
    "email:003", participants=["王琳"], now=t - 5 * DAY, text=(
        "王琳你好，凤凰计划的验收会定于7月18日。预算方案需要在周三前确认。"
        "李强负责准备演示环境。"))
mem.observe_document(
    "email:004", participants=["alice@acme.com"], now=t - 2 * DAY, text=(
        "Alice, following up: Dana prefers the morning slot for the design "
        "review. The API rate limit was confirmed at 1200 requests per minute."))

mem.flush()
print(f"  store: {mem.stats()}")

# ---------------------------------------------------------------------------
hr("2. Retrieve for a live typing context")

print("\nTyping: 'Hi Alice, about the Phoenix launch date, it is'")
snap = mem.retrieve("Hi Alice, about the Phoenix launch date, it is",
                    participants=["alice@acme.com"])
show(snap)

print("\nTyping (zh): '王琳，关于凤凰计划的验收'")
snap_zh = mem.retrieve("王琳，关于凤凰计划的验收", participants=["王琳"])
show(snap_zh)

# ---------------------------------------------------------------------------
hr("3. Slot supersede (bi-temporal): launch date changes")

mem.add_fact(FactDraft(
    text="The Phoenix launch was moved from Aug 15 to Sep 01.",
    entities=("phoenix", "sep 01"), key=("phoenix", "launch_date")),
    source_id="email:005", participants=["alice@acme.com"], now=t)
# a later correction supersedes it via the same key
mem.add_fact(FactDraft(
    text="Final: the Phoenix launch is locked for Sep 10.",
    entities=("phoenix", "sep 10"), key=("phoenix", "launch_date")),
    source_id="email:006", participants=["alice@acme.com"], now=t + 60)

snap = mem.retrieve("the Phoenix launch is", participants=["alice@acme.com"], k=3)
show(snap)
assert "Sep 10" in snap.prompt_block and "Sep 01" not in snap.prompt_block
print("  -> superseded fact excluded, only the current one is retrievable")

# ---------------------------------------------------------------------------
hr("4. Feedback loop: accepted completion reinforces its facts")

before = mem.retrieve("the vendor contract", k=6)
target = next(f for f in before.facts if "Nimbus" in f.text)
print(f"  before: heat(Nimbus fact) = {target.heat.value:.2f}")
for _ in range(3):          # user accepts completions built on this fact
    mem.mark_used([target.fact_id])
print(f"  after 3 accepts: heat = {target.heat.value:.2f} "
      f"-> multiplies BM25 score by (1 + eta*heat) and defers pruning")

# ---------------------------------------------------------------------------
hr("5. Parallel modes")

print("\n5a. Speculative prefetch: poke on word boundary, read snapshot later")
mem.poke_prefetch("Bob, the staging cluster", participants=["bob@acme.com"])
time.sleep(0.15)  # debounce + retrieval happen off-thread
show(mem.snapshot())

print("\n5b. Deadline race (20 ms budget, fired alongside text_fill prefill)")
snap = mem.retrieve_with_deadline("the retro meeting", deadline_s=0.02)
show(snap)

# ---------------------------------------------------------------------------
hr("6. Latency benchmark: 20k synthetic facts")

random.seed(7)
big = DualPathFactMemory()
vocab = ["".join(random.choices(string.ascii_lowercase, k=random.randint(4, 9)))
         for _ in range(3000)]
people = [f"user{i}@corp.com" for i in range(40)]
projects = [f"proj_{w}" for w in vocab[:60]]

t0 = time.perf_counter()
for i in range(20000):
    words = random.choices(vocab, k=10)
    proj = random.choice(projects)
    big.add_fact(FactDraft(
        text=f"The {proj} {' '.join(words[:5])} is due {' '.join(words[5:])}.",
        entities=(proj, random.choice(vocab))),
        source_id=f"doc:{i}", participants=[random.choice(people)],
        now=t - random.uniform(0, 60) * DAY)
print(f"  ingest: 20k facts in {time.perf_counter() - t0:.2f}s "
      f"(cold path -- latency-irrelevant)")
print(f"  store: {big.stats()}")

lat = []
for _ in range(500):
    ctx = ("I wanted to follow up on " + random.choice(projects) + " "
           + " ".join(random.choices(vocab, k=6)))
    t0 = time.perf_counter()
    big.retrieve(ctx, participants=[random.choice(people)], k=6)
    lat.append((time.perf_counter() - t0) * 1000.0)
lat.sort()
print(f"  retrieve over 20k facts: p50={lat[250]:.3f} ms  "
      f"p95={lat[475]:.3f} ms  p99={lat[494]:.3f} ms  max={lat[-1]:.3f} ms")
print("\nDone.")
