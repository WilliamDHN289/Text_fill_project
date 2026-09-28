"""The question W2 asks: is "supersession never fires on open text" a statement
about the mechanism, or about a stateless extractor?

merge_recall runs together two things, so it is printed apart:
  both_turns_keyed   did the extractor key both answer-bearing turns at all
  merge_given_both   given that it did, did it give them the same key
An arm that keys less often can raise one while lowering the other, and the
three arms here key very different shares of the corpus. Only model-linked
shares its keyed turns with its stateless arm by construction, so that pair is
the one comparison free of a coverage difference.

    python3.11 answer_w2.py results/<run>
"""

import json
import sys
from pathlib import Path

run = Path(sys.argv[1] if len(sys.argv) > 1 else "results/iclr27-v3")
real = json.loads((run / "real.json").read_text())
keys = real["longmemeval"]["info"]["keys"]
summary = real["longmemeval"]["summary"]

ARMS = [("stateless|qwen2:7b", "pfm (stateless, qwen2:7b)", "stateless, qwen2:7b"),
        ("key-aware|qwen2:7b", "pfm (key-aware, qwen2:7b)", "store in extraction prompt"),
        ("model-linked|qwen2:7b", "pfm (model-linked, qwen2:7b)", "model-judged linking"),
        ("linked@0.6", "pfm (linked @0.6)", "Jaccard linking @0.6"),
        ("linked@0.4", "pfm (linked @0.4)", "Jaccard linking @0.4"),
        ("stateless|qwen2.5:7b", "pfm (stateless, qwen2.5:7b)", "stateless, qwen2.5:7b"),
        ("model-linked|qwen2.5:7b", "pfm (model-linked, qwen2.5:7b)",
         "model-judged linking, qwen2.5:7b")]

print(f"{'arm':34} {'keyed':>6} {'distinct':>9} {'both':>6} {'merge|both':>11} "
      f"{'merge rec':>10} {'cross-q':>8} {'stale':>7} {'clean':>7}")
for kkey, arm, label in ARMS:
    k = keys.get(kkey)
    if k is None:
        continue
    s = summary.get(arm, {})
    print(f"{label:34} {k['keyed_turns']:6d} {k['distinct_keys']:9d} "
          f"{k['both_turns_keyed']:6.3f} {k.get('merge_given_both', 0):11.3f} "
          f"{k['merge_recall']:10.3f} {k['cross_question_rate']:8.3f} "
          f"{s.get('stale', float('nan')):7.3f} {s.get('clean', float('nan')):7.3f}")

print("\nthe comparison without a coverage difference (same keyed turns by construction):")
for m in ("qwen2:7b", "qwen2.5:7b"):
    a, b = keys.get(f"stateless|{m}"), keys.get(f"model-linked|{m}")
    if not (a and b):
        continue
    print(f"  {m}: merge|both {a.get('merge_given_both', 0):.3f} -> "
          f"{b.get('merge_given_both', 0):.3f}   "
          f"cross-question {a['cross_question_rate']:.3f} -> {b['cross_question_rate']:.3f}   "
          f"distinct {a['distinct_keys']} -> {b['distinct_keys']}")

best = max((keys[k]['merge_recall'], k) for k in keys)
print(f"\nhighest merge recall over every arm: {best[0]:.3f} ({best[1]})")
print("a merge recall still at the .03 level means the claim is about the mechanism;"
      "\nanything higher means it was about stateless per-turn extraction.")
