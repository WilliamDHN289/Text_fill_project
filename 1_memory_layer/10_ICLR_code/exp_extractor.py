"""Construction on text the extractor was not written for.

Stage 1  One fixed local model rewrites every chain message out of the
         benchmark's three templates, keeping names and value tokens. The
         rewriter is held fixed across every arm so that all key assigners read
         exactly the same text; only the key assigner varies.
Stage 2  Construction paths on the rewritten corpus, per key-assigning model:
           rule keys      the template-matched rule extractor of Section 4
           model keys     the model names (entity, slot) for each message
           model updates  no keys; for each new fact the model chooses
                          ADD / UPDATE <id> / DELETE <id> / NOOP over the
                          most similar active facts (a Mem0-style decision)
           keyless        no update resolution at all
         We report key-assignment precision, recall and an error taxonomy
         against the generator's keys, and the prompt-level outcomes of
         Section 6.

The claim under test is an ordering -- whether a model that assigns keys better
by recall also ends with a cleaner prompt -- so it is a paired difference over
the same corpora, reported with a chain-cluster bootstrap interval over several
seeds and a ladder of models.

Model calls are cached by (model, length, prompt) in the run directory, so
re-running is cheap and adding a model never recomputes an existing one.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional

import arms as A
import benchmark as B
import common as C
import exp_llm as L
import extractor as X
import metrics as M
import pfm

KEY_TOKENS, RESOLVE_TOKENS = 48, 8      # a JSON key and a one-line decision are short

SLOTS = {"meeting_time": "meeting", "deadline": "deadline", "launch_date": "launch",
         "day_rate": "rate", "budget_cap": "budget", "room": "room"}

REWRITE = ("Rewrite this work chat message in a different style, as a real person would type "
           "it. Keep every name and every number, time, date, amount or room code exactly as "
           "written. Reply with the rewritten message only, one sentence.\n\nMessage: {text}")

KEY = ("You maintain a memory of facts about people and projects. Each fact fills one slot: "
       "meeting_time, deadline, launch_date, day_rate, budget_cap, room. Read the message and "
       "reply with JSON only: {{\"entity\": name of the person or project the fact is about or "
       "null, \"slot\": one of the six slots or \"none\", \"value\": the value as written or "
       "null}}.\n\nMessage: {text}")

RESOLVE = ("You maintain a memory of facts about people and projects. Decide what to do with a "
           "new statement.\nADD: it states something the memory does not have.\nUPDATE <id>: it "
           "replaces the value of entry <id>, which is about the same thing and the same person "
           "or project (a cancellation replaces the value too).\nDELETE <id>: entry <id> should "
           "be forgotten and nothing replaces it.\nNOOP: it repeats what the memory already "
           "says.\nReply with one line: ADD, UPDATE <id>, DELETE <id>, or NOOP.\n\n"
           "Memory:\n{memory}\nNew statement: {text}")


class Cache:
    """(model, length, prompt) -> completion, persisted as JSON.

    One cache serves every model, so adding a model to the ladder re-runs only
    that model and a re-run of the whole experiment costs no GPU at all."""

    def __init__(self, path: Path, model: str, num_predict: int):
        self.path, self.model, self.num_predict = path, model, num_predict
        self.data: Dict[str, str] = json.loads(path.read_text()) if path.exists() else {}
        self.calls = 0

    def __call__(self, prompt: str, num_predict: int = None, model: str = None) -> str:
        n, m = num_predict or self.num_predict, model or self.model
        key = f"{m}|{n}|{prompt}"
        if key not in self.data:
            self.data[key] = L.generate(m, prompt, n, 300)["text"]
            self.calls += 1
            if self.calls % 50 == 0:
                self.save()
        return self.data[key]

    def save(self) -> None:
        self.path.write_text(json.dumps(self.data))


VALUE_RE = re.compile(r"\$\d[\d,]*k?|\b\d{1,2}:\d{2}\s?[ap]m\b|\b\d{4}-\d{2}-\d{2}\b"
                      r"|\broom \d{1,2}[A-F]\b|\b[A-Z][a-z]{2} \d{1,2}\b")
def restore_values(text: str, values: List[str]) -> Optional[str]:
    """Put each value back in its canonical spelling, or give up on the rewrite."""
    for v in values:
        if B.contains(text, v):
            continue
        m = re.search(B.value_pattern(v), text, re.I)
        if m is None:
            return None
        text = text[:m.start()] + v + text[m.end():]
    return text


def rewrite_corpus(bench: B.Bench, ask: Cache, model: str) -> tuple:
    """Paraphrase chain messages. The paraphrase is kept only if every value and
    name survives, after restoring values the model respelled; otherwise the
    original sentence stays, so the labels remain exact."""
    messages, mapping, stats = [], {}, {"rewritten": 0, "restored": 0, "kept_original": 0}
    for days_ago, partner, text in bench.messages:
        if text not in bench.chain_of:
            messages.append((days_ago, partner, text))
            continue
        new = ask(REWRITE.format(text=text), model=model).strip().strip('"').split("\n")[0]
        values, names = VALUE_RE.findall(text), [g for g in bench.gazetteer
                                                 if g.lower() in text.lower()]
        fixed = restore_values(new, values) if new and len(new) < 300 else None
        if fixed is None or not all(g.lower() in fixed.lower() for g in names):
            new, stats["kept_original"] = text, stats["kept_original"] + 1
        else:
            stats["rewritten"] += 1
            stats["restored"] += fixed != new
            new = fixed
        messages.append((days_ago, partner, new))
        mapping[new] = bench.chain_of[text]
    out = B.Bench(messages, bench.queries, bench.gazetteer, f"{bench.label}-rewritten", mapping)
    return out, {"messages": len(mapping), **stats}


def parse_key(reply: str, gazetteer: List[str]) -> Optional[tuple]:
    m = re.search(r"\{.*\}", reply, re.S)
    try:
        obj = json.loads(m.group(0)) if m else {}
    except json.JSONDecodeError:
        return None
    slot = SLOTS.get(str(obj.get("slot", "")).strip().lower())
    entity = str(obj.get("entity") or "").strip().lower()
    if slot is None or not entity:
        return None
    match = next((g.lower() for g in gazetteer if g.lower() in entity or entity in g.lower()), None)
    return (match, slot) if match else None


def model_key_extractor(ask: Cache, model: str, gazetteer: List[str], log: dict):
    """Drafts keep the rule extractor's text and entities; keys come from the model."""
    base = X.make_rule_extractor(gazetteer)

    def extract(text: str) -> List[pfm.Draft]:
        drafts = base(text)
        key = parse_key(ask(KEY.format(text=text), KEY_TOKENS, model), gazetteer)
        log[text] = key
        return [pfm.Draft(d.text, d.entities, key if i == 0 else None)
                for i, d in enumerate(drafts)]

    return extract


def build_with_model_updates(cfg: dict, bench: B.Bench, ask: Cache, model: str,
                             candidates: int = 5) -> tuple:
    """Keyless drafts; the model chooses ADD / UPDATE / DELETE / NOOP."""
    store = pfm.PFM(cfg["pfm"], X.strip_keys(X.make_keyed_extractor(bench.gazetteer)))
    decisions: Dict[str, int] = {}
    for days_ago, partner, text in bench.messages:
        now = B.BASE - days_ago * B.DAY
        parts = [partner] if isinstance(partner, str) else list(partner)
        for d in store.extractor(text):
            shortlist = [f for f, _ in store.rank(d.text, parts, now)[:candidates]]
            memory = "\n".join(f"{f.fact_id}: {f.text}" for f in shortlist) or "(empty)"
            reply = ask(RESOLVE.format(memory=memory, text=d.text),
                        RESOLVE_TOKENS, model).strip().upper()
            verb = reply.split()[0] if reply else "ADD"
            target = re.search(r"\b(\d+)\b", reply)
            target = int(target.group(1)) if target else None
            valid = target in {f.fact_id for f in shortlist}
            if verb.startswith("UPDATE") and valid:
                store.supersede(target, d, parts, now)
            elif verb.startswith("DELETE") and valid:
                store.close(target, now)
            elif verb.startswith("NOOP"):
                pass
            else:
                verb = "ADD"
                store.ingest_draft(d, parts, now)
            decisions[verb] = decisions.get(verb, 0) + 1
    return store, decisions


def key_quality(bench: B.Bench, predicted: Dict[str, Optional[tuple]], gold: dict) -> dict:
    """Precision, recall and the error taxonomy of (entity, slot) keys.

    The taxonomy is the point of the experiment: recall and precision say how
    many keys are wrong, and the paper's claim is about *which way* they are
    wrong. A missed key leaves a second value active, which the prompt shows; a
    key naming the wrong slot of the right entity merges two slots and deletes
    whichever value arrived first, which nothing shows."""
    counts: Counter = Counter()
    confusions: Counter = Counter()                  # gold slot -> predicted slot
    for _, _, text in bench.messages:
        want = gold.get(bench.chain_of.get(text))
        got = predicted.get(text)
        if want is None:
            counts["spurious" if got is not None else "no_key_wanted"] += 1
        elif got is None:
            counts["missed"] += 1
        elif got == want:
            counts["correct"] += 1
        else:
            bad_e, bad_s = got[0] != want[0], got[1] != want[1]
            counts["wrong_both" if bad_e and bad_s else
                   "wrong_slot" if bad_s else "wrong_entity"] += 1
            if bad_s:
                confusions[f"{want[1]}->{got[1]}"] += 1
    tp, fn = counts["correct"], counts["missed"]
    fp = counts["spurious"] + counts["wrong_slot"] + counts["wrong_entity"] + counts["wrong_both"]
    return {"precision": tp / max(1, tp + fp), "recall": tp / max(1, tp + fn),
            "n_errors": fp + fn, "errors": dict(counts),
            "slot_confusions": dict(confusions.most_common())}


def gold_keys(bench: B.Bench) -> tuple:
    """The generator's (entity, slot) key per chain, read off the template text."""
    rule, gold = X.make_keyed_extractor(bench.gazetteer), {}
    for _, _, text in bench.messages:
        keys = [d.key for d in rule(text) if d.key]
        if text in bench.chain_of and keys:
            gold[bench.chain_of[text]] = keys[0]
    return gold, rule


def run(cfg: dict, out) -> dict:
    ecfg, r = cfg["extractor"], cfg["pfm"]["retrieval"]
    seeds = ecfg.get("seeds") or cfg["benchmark"]["seeds"][:1]
    models = ecfg.get("models") or [ecfg["model"]]
    rewriter = ecfg.get("rewriter", models[0])
    update_seeds = set(ecfg.get("update_seeds", seeds))
    ask = Cache(out / "extractor_cache.json", rewriter, ecfg["num_predict"])

    # Stage 1, once per seed: one rewriter for every arm, so the text is shared.
    corpora, rewrite_stats, examples = {}, {}, []
    for seed in seeds:
        bench = C.make_bench(cfg, seed, ecfg["corpus"])
        rewritten, stats = rewrite_corpus(bench, ask, rewriter)
        ask.save()
        corpora[seed] = (bench, rewritten, gold_keys(bench)[0])
        rewrite_stats[seed] = stats
        examples += [{"seed": seed, "original": o, "rewritten": n}
                     for (_, _, o), (_, _, n) in list(zip(bench.messages,
                                                          rewritten.messages))[:3] if o != n]
        print(f"  seed {seed}: rewrote {stats['rewritten']}/{stats['messages']} messages "
              f"({stats['restored']} value spellings restored, "
              f"{stats['kept_original']} left as templates)", flush=True)

    # Stage 2, model-outer so each model is loaded once.
    rows, quality, decisions = [], {}, {}

    def keep(built, bench, **tags):
        reach = C.reachable(built, bench.queries)
        rows.extend(dict(row, lost_current=row["qid"] not in reach, **tags)
                    for row in C.evaluate(A.PFMArm(built, tags["store"]), bench,
                                          r["k"], r["budget"], seed=tags["seed"]))

    for seed, (bench, rewritten, gold) in corpora.items():       # model-free arms, once
        rule = X.make_keyed_extractor(rewritten.gazetteer)
        on_rewritten = {text: next((d.key for d in rule(text) if d.key), None)
                        for _, _, text in rewritten.messages}
        quality[f"rule keys|{seed}"] = key_quality(rewritten, on_rewritten, gold)
        keep(C.build_store(cfg["pfm"], rewritten), rewritten, store="rule keys",
             model="rule", seed=seed)
        keep(C.build_store(cfg["pfm"], rewritten, keyed=False), rewritten, store="keyless",
             model="rule", seed=seed)
        keep(C.build_store(cfg["pfm"], bench), bench, store="rule keys, template corpus",
             model="rule", seed=seed)

    for model in models:
        for seed, (bench, rewritten, gold) in corpora.items():
            log: Dict[str, Optional[tuple]] = {}
            store = C.build_store(cfg["pfm"], rewritten,
                                  extractor=model_key_extractor(ask, model,
                                                                rewritten.gazetteer, log))
            ask.save()
            quality[f"model keys|{model}|{seed}"] = key_quality(rewritten, log, gold)
            keep(store, rewritten, store="model keys", model=model, seed=seed)

            # The Mem0-shaped path is a contrast rather than the claim under
            # test, so it runs across the model ladder at one seed.
            if seed in update_seeds:
                upd, dec = build_with_model_updates(cfg, rewritten, ask, model)
                ask.save()
                decisions[f"{model}|{seed}"] = dec
                keep(upd, rewritten, store="model updates", model=model, seed=seed)
            q = quality[f"model keys|{model}|{seed}"]
            print(f"  {model} seed {seed}: key recall {q['recall']:.3f} "
                  f"precision {q['precision']:.3f}", flush=True)

    M.write_jsonl(out / "extractor.jsonl", rows)
    result = {"rewrite": rewrite_stats, "rewriter": rewriter, "models": models, "seeds": seeds,
              "key_quality": quality, "update_decisions": decisions,
              "corpus": ecfg["corpus"], "cached_calls": len(ask.data),
              "summary": {f"{s}|{m}": M.summarize(rs, ci=False)["all"]
                          for (s, m), rs in M.group(rows, "store", "model").items()},
              "paired": paired_vs_rule(rows, models), "examples": examples[:8]}
    C.write_json(out / "extractor.json", result)
    return result


def paired_vs_rule(rows: List[dict], models: List[str]) -> dict:
    """Clean retrieval of each model path minus the rule extractor's, on the
    same queries, pooled over seeds with a chain-cluster bootstrap interval."""
    by = M.group(rows, "store", "model")
    rule = by[("rule keys", "rule")]
    out = {}
    for store in ("model keys", "model updates"):
        for model in models:
            arm = by.get((store, model))
            if arm:
                out[f"{store}|{model}"] = M.paired_difference(arm, rule)
    out["keyless|rule"] = M.paired_difference(by[("keyless", "rule")], rule)
    return out
