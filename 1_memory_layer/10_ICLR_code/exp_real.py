"""The three axes on corpora we did not write.

A  LongMemEval, knowledge-update    staleness and open-domain key discovery
B  LoCoMo, name-sharing speakers    misattribution, judged by provenance
C  LoCoMo, foreign questions        abstention when the store has no answer

The synthetic benchmark hands the store a slot vocabulary and an (entity,
slot) key. Neither exists here, so keys come from a model asked to name an
entity and an attribute and to reuse that wording when the same property is
stated again. Two diagnostics say whether it managed, and neither needs a key
annotation: how often the two annotated answer-bearing turns of a
knowledge-update question received the same key, which is the merge
supersession depends on, and how often turns belonging to different questions
received the same key, which is the false merge that deletes a value.
"""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Tuple

import arms as A
import benchmark as B
import common as C
import exp_extractor as E
import extractor as X
import identity as I
import metrics as M
import pfm
import realdata as R

OPEN_KEY = (
    "You keep a memory of durable facts about one user. Read the message and reply with JSON "
    "only:\n{{\"entity\": what the fact is about, a short noun phrase, or null,\n "
    "\"attribute\": the property being stated about it, a short noun phrase, or null,\n "
    "\"value\": the value of that property, copied from the message, or null}}\n"
    "Use the same entity and attribute wording every time the same property is stated, so a "
    "later message about it replaces the earlier one. If the message states no durable fact, "
    "reply with all three null.\n\nMessage: {text}")

# The stateless instruction, unchanged, followed by the wording already in the
# store. Order matters: a candidate list placed before the task turns the model
# into a filter that answers null whenever the turn matches nothing listed, which
# would change how often it keys at all and not just how often it merges. The
# calibration target is therefore the keying rate of the stateless prompt -- a
# fairness criterion independent of the merge rate this experiment measures.
OPEN_KEY_AWARE = (
    "You keep a memory of durable facts about one user. Read the message and reply with JSON "
    "only:\n{{\"entity\": what the fact is about, a short noun phrase, or null,\n "
    "\"attribute\": the property being stated about it, a short noun phrase, or null,\n "
    "\"value\": the value of that property, copied from the message, or null}}\n"
    "Use the same entity and attribute wording every time the same property is stated, so a "
    "later message about it replaces the earlier one. If the message states no durable fact, "
    "reply with all three null.\n"
    "Wording you have already used, so you can match it when this message states one of these "
    "same properties:\n{keys}\n\nMessage: {text}")

LINK_JUDGE = (
    "You keep a memory of durable facts about one user, each filed under an "
    "(entity / attribute) key.\n\nA new statement was filed under:\n  {new}\n\n"
    "Keys already in the memory:\n{keys}\n\n"
    "Does the new key name the same property of the same thing as one of them, so that the new "
    "statement replaces the old value? Reply with the number of that key, or 0 if it names a "
    "different property. Reply with the number only.")

KEY_TOKENS = 32                     # a three-field JSON key
LINK_TOKENS = 4                     # a single number
AWARE_TOKENS = 40                   # room for "reuse" plus a copied value
_ARTICLE = re.compile(r"^(?:the|a|an|my|our|his|her|their|your)\s+")
_WORD = re.compile(r"[a-z0-9]+")


def norm_key_part(s: str) -> str:
    s = _ARTICLE.sub("", str(s or "").strip().lower())
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return re.sub(r"\b(\w{4,})s\b", r"\1", s)


_FIELD = re.compile(r'"(entity|attribute|value)"\s*:\s*(?:"([^"]*)"|([^",}\n]+))')


def parse_open_key(reply: str) -> Tuple[Optional[tuple], str]:
    """The model's three-field key, or None if it named no durable fact.

    The fields are read directly rather than through a JSON parse: a small
    model sometimes drops the quotes around a value, and a strict parse would
    throw the whole reply away. Both the stateless and the key-aware extractor
    parse through here, so neither is favoured by a difference in leniency."""
    m = re.search(r"\{.*\}", reply, re.S)
    if m is None:
        return None, ""
    obj = {k: (q or bare.strip()) for k, q, bare in _FIELD.findall(m.group(0))}
    ent, attr = norm_key_part(obj.get("entity")), norm_key_part(obj.get("attribute"))
    if not ent or not attr or ent == "null" or attr == "null":
        return None, ""
    value = obj.get("value", "")
    return (ent, attr), "" if value.lower() == "null" else value


def candidate_keys(text: str, known: List[tuple], n: int) -> List[tuple]:
    """The keys this turn is most likely to restate: content-word overlap first,
    most recently created as the tie-break and as filler."""
    toks = {w for w in _WORD.findall(text.lower()) if w not in pfm.STOPWORDS}
    ranked = sorted(enumerate(known),
                    key=lambda ik: (-len(toks & set(" ".join(ik[1]).split())), -ik[0]))
    return [k for _, k in ranked[:n]]


def key_aware_extractor(ask, log: Dict[str, Optional[tuple]], n_candidates: int, model: str):
    """Open-domain keys with the store in view.

    The stateless extractor is called once per turn and cannot coordinate its
    wording, which is why its keys almost never coincide. This one is shown the
    keys already assigned and asked to copy one when the turn restates that
    property -- the resolution a deployed system would do inside the extractor
    rather than after it. It is the condition under which "supersession never
    fires on open text" is a statement about the mechanism rather than about a
    stateless extractor. The reply schema is the stateless one, so the two
    differ only in what the model was shown."""
    base = X.make_open_extractor()
    known: List[tuple] = []

    def extract(text: str) -> List[pfm.Draft]:
        drafts = base(text)
        if not drafts:
            return drafts
        cands = candidate_keys(text, known, n_candidates)
        listing = "\n".join(f"{e} / {a}" for e, a in cands) or "(none yet)"
        key, value = parse_open_key(
            ask(OPEN_KEY_AWARE.format(keys=listing, text=text), AWARE_TOKENS, model))
        log[text] = key
        if key is None:
            return drafts
        if key not in known:
            known.append(key)
        hit = next((i for i, d in enumerate(drafts) if value and B.contains(d.text, value)), 0)
        return [pfm.Draft(d.text, d.entities, key if i == hit else None)
                for i, d in enumerate(drafts)]

    return extract


def replay_extractor(keys: Dict[str, Optional[tuple]]):
    """The open extractor with keys taken from a precomputed map, so a linked
    variant costs no further model calls."""
    base = X.make_open_extractor()

    def extract(text: str) -> List[pfm.Draft]:
        drafts, key = base(text), keys.get(text)
        if not drafts or key is None:
            return drafts
        return [pfm.Draft(d.text, d.entities, key if i == 0 else None)
                for i, d in enumerate(drafts)]

    return extract


def open_key_extractor(ask, log: Dict[str, Optional[tuple]], model: str):
    """Sentences from the open extractor; the model's key goes to the sentence
    that carries the value it reported, or to the first one if it named none."""
    base = X.make_open_extractor()

    def extract(text: str) -> List[pfm.Draft]:
        drafts = base(text)
        if not drafts:
            return drafts
        key, value = parse_open_key(ask(OPEN_KEY.format(text=text), KEY_TOKENS, model))
        log[text] = key
        if key is None:
            return drafts
        hit = next((i for i, d in enumerate(drafts)
                    if value and B.contains(d.text, value)), 0)
        return [pfm.Draft(d.text, d.entities, key if i == hit else None)
                for i, d in enumerate(drafts)]

    return extract


def link_keys(order: List[str], keys: Dict[str, Optional[tuple]],
              theta: float) -> Dict[str, Optional[tuple]]:
    """Canonicalize model-assigned keys in arrival order.

    A model asked one message at a time cannot coordinate its wording across
    messages. It also splits the same fact differently on different calls, so
    one turn yields ("personal best time", "time") and the next ("user",
    "personal best time"); an exact match on the entity string would never put
    them together. The linker therefore compares the combined token set of
    entity and attribute and merges a new key into an existing one when their
    Jaccard similarity reaches `theta`, which is the knob between missed and
    false merges. This is the deterministic resolution step a deployed system
    runs after the extractor, and it costs no further model call."""
    canon: List[tuple] = []                               # [(tokens, key)]
    out: Dict[str, Optional[tuple]] = {}
    for text in order:
        k = keys.get(text)
        if k is None:
            out[text] = None
            continue
        toks = set(" ".join(k).split())
        best, score = None, theta
        for prev, key in canon:
            j = len(toks & prev) / len(toks | prev)
            if j >= score:
                best, score = key, j
        if best is None:
            best = k
            canon.append((toks, k))
        out[text] = best
    return out


def model_link_keys(order: List[str], keys: Dict[str, Optional[tuple]], ask, model: str,
                    n_candidates: int) -> Dict[str, Optional[tuple]]:
    """`link_keys`, with the model rather than a Jaccard threshold deciding.

    This is the §8 variant -- the extractor is given sight of the keys already in
    the store -- placed at resolution rather than inside extraction. Putting the
    candidate list in the extraction prompt makes the model answer "no durable
    fact" three times as often, which would change how often it keys at all and
    not only how often it merges. Here the keys are the stateless ones, so the
    share of turns that get a key is identical by construction and the merge
    decision is the only thing that differs. Only a key sharing a token with an
    existing one is put to the model, so this costs one short call per plausible
    pair rather than one per turn."""
    canon: List[tuple] = []
    out: Dict[str, Optional[tuple]] = {}
    decided: Dict[tuple, tuple] = {}
    for text in order:
        k = keys.get(text)
        if k is None:
            out[text] = None
            continue
        if k in decided:
            out[text] = decided[k]
            continue
        toks = set(" ".join(k).split())
        cands = [c for c in candidate_keys(" ".join(k), canon, n_candidates)
                 if toks & set(" ".join(c).split())]
        chosen = k
        if cands:
            listing = "\n".join(f"{i + 1}. {e} / {a}" for i, (e, a) in enumerate(cands))
            reply = ask(LINK_JUDGE.format(new=" / ".join(k), keys=listing), LINK_TOKENS, model)
            m = re.search(r"\d+", reply or "")
            i = int(m.group(0)) if m else 0
            if 0 < i <= len(cands):
                chosen = cands[i - 1]
        if chosen == k:
            canon.append(k)
        decided[k] = chosen
        out[text] = chosen
    return out


def build(cfg: dict, bench: B.Bench, extractor) -> Tuple[pfm.PFM, Dict[int, str]]:
    """Ingest in arrival order, recording which source message each fact came
    from so provenance can be checked later."""
    store = pfm.PFM(cfg, extractor)
    origin: Dict[int, str] = {}
    for days_ago, partner, text in bench.messages:
        parts = [partner] if isinstance(partner, str) else list(partner)
        for f in store.ingest(text, parts, B.BASE - days_ago * B.DAY):
            origin[f.fact_id] = bench.chain_of.get(text, "")
    return store, origin


def key_diagnostics(bench: B.Bench, keys: Dict[str, Optional[tuple]]) -> dict:
    """Open-domain key quality without a key annotation. `merge_recall` is the
    share of knowledge-update questions whose two answer-bearing turns share a
    key; `cross_merge` counts keys shared by turns of different questions."""
    by_question: Dict[str, List[Optional[tuple]]] = defaultdict(list)
    owners: Dict[tuple, set] = defaultdict(set)
    for _, _, text in bench.messages:
        k = keys.get(text)
        owner = bench.chain_of.get(text, "")
        if k is not None:
            owners[k].add(owner)
    for q in bench.queries:
        for text in q.meta.get("answer_turns", ()):
            by_question[q.qid].append(keys.get(text))
    merged = sum(1 for ks in by_question.values()
                 if len(ks) > 1 and ks[0] is not None and len(set(ks)) == 1)
    both = sum(1 for ks in by_question.values() if len(ks) > 1 and all(k is not None for k in ks))
    # merge_recall runs together two things an extractor can get wrong: keying
    # both turns at all, and giving them the same key. Reported apart, because a
    # variant that keys less often can raise one while lowering the other.
    assigned = sum(k is not None for k in keys.values())
    return {"turns": len(keys), "keyed_turns": assigned,
            "distinct_keys": len(owners),
            "merge_recall": merged / max(1, len(by_question)),
            "both_turns_keyed": both / max(1, len(by_question)),
            "merge_given_both": merged / both if both else 0.0,
            "merged_questions": merged, "questions": len(by_question),
            "cross_question_keys": sum(len(v) > 1 for v in owners.values()),
            "cross_question_rate": sum(len(v) > 1 for v in owners.values()) / max(1, len(owners))}


# -- A: LongMemEval --------------------------------------------------------

def longmemeval(cfg: dict, out, ask) -> dict:
    r = cfg["pfm"]["retrieval"]
    bench, info = R.longmemeval(lambda p: ask(p, 32), distractors=cfg["real"]["distractors"])
    answer_turns = _answer_turns()
    for q in bench.queries:
        q.meta["answer_turns"] = answer_turns.get(q.qid, [])
    ask.save()
    # Two ways of assigning a key, on each of two models: stateless (one call per
    # turn, nothing in view) and key-aware (the keys already assigned are shown).
    # The pair is what says whether "supersession never fires here" is about the
    # mechanism or about a stateless extractor, and the second model says whether
    # it is about model capability.
    models = cfg["real"]["key_models"]
    stores, keysets = {}, {}
    for m in models:
        modes = [("stateless", open_key_extractor)]
        if m in cfg["real"]["key_aware_extract"]:
            modes.append(("key-aware", lambda a, lg, mdl: key_aware_extractor(
                a, lg, cfg["real"]["key_aware_candidates"], mdl)))
        for mode, make in modes:
            log: Dict[str, Optional[tuple]] = {}
            stores[f"pfm ({mode}, {m})"] = build(cfg["pfm"], bench, make(ask, log, m))[0]
            keysets[f"{mode}|{m}"] = log
            ask.save()
            print(f"  {mode} keys, {m}: "
                  f"{sum(k is not None for k in log.values())} of {len(log)} turns keyed",
                  flush=True)
    primary = f"stateless|{models[0]}"
    keyed = stores[f"pfm (stateless, {models[0]})"]
    stores["pfm, keyless"] = build(cfg["pfm"], bench, X.make_open_extractor())[0]

    # Two post-hoc resolvers over the same stateless keys, so all three arms key
    # the same turns and differ only in how they decide a merge: a Jaccard
    # threshold, and the model shown the candidates.
    order = [t for _, _, t in bench.messages]
    linked = {th: link_keys(order, keysets[primary], th) for th in cfg["real"]["link_theta"]}
    for th, mapping in linked.items():
        stores[f"pfm (linked @{th})"] = build(cfg["pfm"], bench, replay_extractor(mapping))[0]

    for m in models:
        mapping = model_link_keys(order, keysets[f"stateless|{m}"], ask, m,
                                  cfg["real"]["key_aware_candidates"])
        ask.save()
        stores[f"pfm (model-linked, {m})"] = build(cfg["pfm"], bench,
                                                   replay_extractor(mapping))[0]
        keysets[f"model-linked|{m}"] = mapping
        print(f"  model-linked keys, {m}: "
              f"{len({v for v in mapping.values() if v})} distinct", flush=True)

    diagnostics = {**{k: key_diagnostics(bench, log) for k, log in keysets.items()},
                   **{f"linked@{th}": key_diagnostics(bench, mp) for th, mp in linked.items()}}

    arms = [A.PFMArm(stores[n], n) for n in stores if n.startswith("pfm (")
            and not n.startswith("pfm, ")]
    arms += [A.PFMArm(stores["pfm, keyless"], "pfm, keyless"),
             A.BM25Arm(keyed), A.BM25Arm(keyed, recency=True),
             A.BM25Arm(keyed, valid_only=True)]
    if cfg["real"]["dense"]:
        arms.append(A.DenseArm(keyed, A.Encoder(cfg["dense"]), valid_only=True))
    for q in bench.queries:                    # the turns were only needed above
        q.meta.pop("answer_turns", None)
    rows = []
    for arm in arms:
        rows += [dict(row, corpus="longmemeval")
                 for row in C.evaluate(arm, bench, r["k"], cfg["real"]["budget"], seed=0)]
    return {"rows": rows,
            "info": {**info, "keys": diagnostics,
                     "store": keyed.stats(), "budget": cfg["real"]["budget"]},
            "summary": {a: M.summarize(rs, ci=False)["all"]
                        for (a,), rs in M.group(rows, "arm").items()}}


def _answer_turns() -> Dict[str, List[str]]:
    data = json.loads(R.LME.read_text())
    return {e["question_id"]: [t["content"].strip() for s in e["haystack_sessions"] for t in s
                               if t.get("role") == "user" and t.get("has_answer")]
            for e in data if e["question_type"] == "knowledge-update"}


# -- B and C: LoCoMo -------------------------------------------------------

def locomo(cfg: dict, out) -> dict:
    r, rcfg = cfg["pfm"]["retrieval"], cfg["real"]
    bench, info = R.locomo()
    store, origin = build(cfg["pfm"], bench, X.make_open_extractor())
    base = A.PFMArm(store)
    rows = []
    for arm in (base, A.ParticipantFilter(base), I.ContextAffinity(base, store),
                A.ParticipantFilter(I.ContextAffinity(base, store))):
        for q in bench.queries:
            block, ranked, ms = A.serve(arm, q.prefix, [q.partner], B.BASE,
                                        r["k"], rcfg["budget"])
            shown = [f for f, _ in ranked][:block.count("\n- ")]
            foreign = [origin.get(f.fact_id, "") for f in shown]
            rivals = set(q.meta["rivals"])
            rows.append(M.row(q, arm=arm.name, corpus="locomo", latency_ms=ms,
                              **{**M.outcome(block, q),
                                 "wrong": any(o in rivals for o in foreign),
                                 "offconv": sum(o not in (q.meta["owner"], "") for o in foreign),
                                 "shown": len(foreign)}))
    for row in rows:                                    # clean must follow the new `wrong`
        row["clean"] = row["current"] and not row["stale"] and not row["wrong"]

    # abstention: each conversation's own store, asked its own and foreign questions
    abst = []
    by_conv = defaultdict(list)
    for q in bench.queries:
        by_conv[q.meta["owner"]].append(q)
    for conv, own in sorted(by_conv.items()):
        sub = B.Bench([m for m in bench.messages if bench.chain_of.get(m[2]) == conv],
                      [], [], conv, bench.chain_of)
        s, _ = build(cfg["pfm"], sub, X.make_open_extractor())
        foreign = [q for c, qs in by_conv.items() if c != conv
                   for q in qs[:rcfg["foreign_per_conversation"]]]
        probe = [(q, True) for q in own] + [(q, False) for q in foreign]
        inner = A.PFMArm(s)
        for arm in [inner] + [I.MarginAbstain(inner, t) for t in rcfg["abstain_tau"]]:
            for q, answerable in probe:
                block, _, _ = A.serve(arm, q.prefix, [q.partner], B.BASE,
                                      r["k"], rcfg["budget"])
                abst.append({"qid": f"{conv}|{q.qid}", "chain": conv, "seed": 0,
                             "arm": arm.name, "answerable": answerable,
                             "current": answerable and B.contains(block, q.current),
                             "abstain": not block.strip(), "stale": False, "wrong": False,
                             "coinject": False,
                             "clean": (B.contains(block, q.current) if answerable
                                       else not block.strip())})
    off = {a: sum(r["offconv"] for r in rs) / max(1, sum(r["shown"] for r in rs))
           for (a,), rs in M.group(rows, "arm").items()}
    return {"rows": rows, "abstention": abst,
            "info": {**info, "store": store.stats(), "off_conversation_fact_share": off},
            "summary": {a: M.summarize(rs, ("all", "ambiguous"), ci=False)
                        for (a,), rs in M.group(rows, "arm").items()},
            "abstention_summary": {a: M.summarize(rs, ("answerable", "unanswerable"),
                                                  ("current", "abstain", "clean"), ci=False)
                                   for (a,), rs in M.group(abst, "arm").items()}}


def run(cfg: dict, out) -> dict:
    ask = E.Cache(out / "real_cache.json", cfg["real"]["model"], E.KEY_TOKENS)
    lme = longmemeval(cfg, out, ask)
    ask.save()
    print(f"  longmemeval: {lme['info']['labelled']}/{lme['info']['questions']} labelled", flush=True)
    for name, k in lme["info"]["keys"].items():
        print(f"    {name:26} merge recall {k['merge_recall']:.3f}  "
              f"merged|both {k['merge_given_both']:.3f}  cross-q {k['cross_question_rate']:.3f}",
              flush=True)
    loc = locomo(cfg, out)
    M.write_jsonl(out / "real.jsonl", lme["rows"] + loc["rows"])
    M.write_jsonl(out / "real_abstention.jsonl", loc["abstention"])
    result = {"longmemeval": {k: v for k, v in lme.items() if k != "rows"},
              "locomo": {k: v for k, v in loc.items() if k not in ("rows", "abstention")},
              "cached_calls": len(ask.data)}
    C.write_json(out / "real.json", result)
    return result
