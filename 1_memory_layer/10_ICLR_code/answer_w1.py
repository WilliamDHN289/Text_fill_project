"""The ordering W1 asks about, read straight off the extractor logs.

Does a key assigner with higher recall end with a cleaner prompt? Prints the
ladder with clean retrieval and its paired difference from the rule extractor,
and the error taxonomy that decides it.

    python3.11 answer_w1.py results/<run>
"""

import json
import sys
from pathlib import Path

import metrics as M

run = Path(sys.argv[1] if len(sys.argv) > 1 else "results/iclr27-v3")
info = json.loads((run / "extractor.json").read_text())
rows = M.read_jsonl(run / "extractor.jsonl")
metrics = M.METRICS + ("lost_current",)


def pooled(tag):
    from collections import Counter
    c, conf = Counter(), Counter()
    for k, q in info["key_quality"].items():
        if k.rsplit("|", 1)[0] == tag:
            c.update(q["errors"])
            conf.update(q["slot_confusions"])
    tp, fn = c["correct"], c["missed"]
    fp = c["spurious"] + c["wrong_slot"] + c["wrong_entity"] + c["wrong_both"]
    return tp / max(1, tp + fp), tp / max(1, tp + fn), c, conf


def cells(store, model):
    rs = [r for r in rows if r["store"] == store and r["model"] == model]
    return M.summarize(rs, ci=False, metrics=metrics)["all"] if rs else None


print(f"corpus: {info.get('corpus', '?')}  seeds: {info.get('seeds')}  "
      f"rewriter: {info.get('rewriter')} (held fixed)")
print(f"\n{'key assigner':22} {'prec':>6} {'recall':>7} {'clean':>7} {'lost':>6} "
      f"{'stale':>7}  paired diff vs rule (95% CI)")
p, r, _, _ = pooled("rule keys")
c = cells("rule keys", "rule")
print(f"{'rule extractor':22} {p:6.3f} {r:7.3f} {c['clean']:7.3f} {c['lost_current']:6.3f} "
      f"{c['stale']:7.3f}  --")
for m in info["models"]:
    p, r, _, _ = pooled(f"model keys|{m}")
    c = cells("model keys", m)
    d = info["paired"].get(f"model keys|{m}")
    ci = f"{d['diff']:+.3f} ({d['ci'][0]:+.3f}, {d['ci'][1]:+.3f})" if d else "--"
    print(f"{m:22} {p:6.3f} {r:7.3f} {c['clean']:7.3f} {c['lost_current']:6.3f} "
          f"{c['stale']:7.3f}  {ci}")

print("\nkey errors, pooled over seeds")
print(f"{'assigner':22} {'correct':>8} {'missed':>7} {'wrong slot':>11} {'wrong ent':>10}  "
      f"commonest confusion")
for tag, label in [("rule keys", "rule extractor")] + [(f"model keys|{m}", m)
                                                       for m in info["models"]]:
    _, _, c, conf = pooled(tag)
    top = max(conf.items(), key=lambda kv: kv[1], default=("--", 0))
    print(f"{label:22} {c['correct']:8d} {c['missed']:7d} "
          f"{c['wrong_slot'] + c['wrong_both']:11d} {c['wrong_entity']:10d}  "
          f"{top[0]} ({top[1]})")

print("\nordering: does higher key recall mean cleaner prompts?")
pairs = sorted(((pooled(f"model keys|{m}")[1], cells("model keys", m)["clean"], m)
                for m in info["models"]), reverse=True)
for rec, clean, m in pairs:
    print(f"  recall {rec:.3f} -> clean {clean:.3f}   {m}")
rule_rec, rule_clean = pooled("rule keys")[1], cells("rule keys", "rule")["clean"]
print(f"  recall {rule_rec:.3f} -> clean {rule_clean:.3f}   rule extractor")
beaten = [m for _, cl, m in pairs if cl < rule_clean]
print(f"\nmodels with higher key recall but lower clean retrieval than the rule: "
      f"{beaten or 'none'}")
