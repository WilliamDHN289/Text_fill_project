"""Benchmark slices for cases the main update benchmark does not contain.

multi_valued   one person holds two instances of the same slot type, so a
               key at (entity, slot) granularity merges them
hard_identity  two people sharing a first name hold the same slot, with the
               same noun, template, and age; plus queries that have no answer
reorder        the same corpus delivered out of arrival order
participants   facts about a third party, in group threads, or with the
               participant missing

Each returns a `benchmark.Bench`, so the existing arms and metrics apply.
Messages carry either one participant or a tuple of them.
"""

from __future__ import annotations

import random
from typing import List, Tuple

import benchmark as B

MEETING = B.SLOTS["meeting"]                       # (kind, nouns, value fn, msg tpl, query tpl)
FIRST_NAMES = ["Alex", "Maya", "Jordan", "Dana", "Robin", "Sasha",
               "Priya", "Elena", "Leo", "Grace", "Hana", "Marco"]
SURNAMES = [("Chen", "Rivera"), ("Patel", "Song"), ("Fox", "Lindt"), ("Wolf", "Okafor"),
            ("Hale", "Castro"), ("Bell", "Moreau"), ("Nair", "Iyer"), ("Ruiz", "Costa"),
            ("Marchetti", "Dvorak"), ("Obi", "Mensah"), ("Sato", "Mori"), ("Deluca", "Rossi")]


def _chain_messages(pool: B.ValuePool, rng: random.Random, entity: str, noun: str,
                    partner: str, revisions: int, template: int = None, span=(8, 27)):
    """One revision chain: (messages, current value, stale values)."""
    _, _, vfn, msg_tpl, _ = MEETING
    values = [getattr(pool, vfn)() for _ in range(revisions + 1)]
    start = rng.uniform(*span)
    ages = [start] + sorted([rng.uniform(0.3, start - 0.5) for _ in range(revisions)], reverse=True)
    msgs = [(age, partner,
             msg_tpl[j % 3 if template is None else template].format(noun=noun, ent=entity, v=v))
            for j, (age, v) in enumerate(zip(ages, values))]
    return msgs, values[-1], values[:-1]


def _bench(messages, queries, gazetteer, label, chain_of) -> B.Bench:
    messages.sort(key=lambda m: -m[0])
    return B.Bench(messages=messages, queries=queries, gazetteer=gazetteer, label=label,
                   chain_of=chain_of)


def multi_valued(n_people: int, seed: int, revisions: int = 2, n_fillers: int = 200) -> B.Bench:
    """Two standing meetings per person: a standup and a sync, each revised."""
    rng = random.Random(seed)
    pool = B.ValuePool(rng)
    people = B.PEOPLE[B.AMBIG_N:B.AMBIG_N + n_people]
    messages, queries, chain_of = [], [], {}
    for i, person in enumerate(people):
        for j, noun in enumerate(("standup", "sync")):
            chain = 2 * i + j
            msgs, current, stale = _chain_messages(pool, rng, person, noun, person, revisions)
            messages += msgs
            chain_of.update({m[2]: chain for m in msgs})
            first = person.split()[0]
            queries.append(B.Query(
                qid=f"multi-s{seed}-c{chain}-q0", partner=person,
                prefix=MEETING[4][0].format(noun=noun, ent=person, first=first),
                current=current, stale=stale, wrong=[],
                meta=dict(chain=chain, slot="meeting", revisions=revisions, verbatim=False,
                          cancel=False, ambiguous=False, q_level=0, age_days=0.0,
                          distractors=2 * n_people - 1, noun=noun, case="multi_valued")))
    messages += B.fillers(n_fillers)
    return _bench(messages, queries, B.PEOPLE + B.PROJECTS, f"multi-s{seed}", chain_of)


def hard_identity(n_pairs: int, seed: int, revisions: int = 1,
                  n_fillers: int = 200) -> B.Bench:
    """Same first name, same slot, same noun, same template, ages one day apart.
    Half the people also get a query about a slot nobody filled for them."""
    rng = random.Random(seed)
    pool = B.ValuePool(rng)
    messages, queries, chain_of, people = [], [], {}, []
    chains: List[Tuple[str, str, List[str]]] = []
    for i in range(n_pairs):
        first, (a, b) = FIRST_NAMES[i], SURNAMES[i]
        pair = [f"{first} {a}", f"{first} {b}"]
        people += pair
        start = rng.uniform(9, 20)
        for j, person in enumerate(pair):
            chain = 2 * i + j
            msgs, current, stale = _chain_messages(
                pool, rng, person, "standup", person, revisions, template=0,
                span=(start, start + 1))
            messages += msgs
            chain_of.update({m[2]: chain for m in msgs})
            chains.append((person, current, stale))
            queries.append(B.Query(
                qid=f"hard-s{seed}-c{chain}-q0", partner=person,
                prefix=MEETING[4][0].format(noun="standup", ent=person, first=first),
                current=current, stale=stale, wrong=[],
                meta=dict(chain=chain, slot="meeting", revisions=revisions, verbatim=False,
                          cancel=False, ambiguous=True, q_level=0, age_days=0.0,
                          distractors=2 * n_pairs - 1, noun="standup", case="hard_identity")))
    for q in queries:                                  # competitor values, filled in afterwards
        first = q.partner.split()[0]
        q.wrong = [c for person, c, _ in chains
                   if person != q.partner and person.split()[0] == first]
    all_values = [v for _, c, st in chains for v in [c] + st]
    for i, person in enumerate(people[::2]):           # unanswerable: no room fact exists
        queries.append(B.Query(
            qid=f"hard-s{seed}-u{i}-q0", partner=person,
            prefix=B.SLOTS["room"][4][0].format(noun="standup", ent=person,
                                                first=person.split()[0]),
            current=None, stale=[], wrong=all_values,
            meta=dict(chain=f"u{i}", slot="room", revisions=0, verbatim=False, cancel=False,
                      ambiguous=True, q_level=0, age_days=0.0, distractors=2 * n_pairs,
                      noun="standup", case="unanswerable")))
    messages += B.fillers(n_fillers)
    return _bench(messages, queries, people + B.PROJECTS, f"hard-s{seed}", chain_of)


def reorder(bench: B.Bench, fraction: float, seed: int) -> B.Bench:
    """Deliver a fraction of the chains out of order: the messages keep their
    stated times but arrive shuffled."""
    rng = random.Random(seed)
    positions: dict = {}
    for i, (_, _, text) in enumerate(bench.messages):
        if text in bench.chain_of:
            positions.setdefault(bench.chain_of[text], []).append(i)
    messages = list(bench.messages)
    reordered = 0
    for chain, pos in positions.items():
        if len(pos) > 1 and rng.random() < fraction:
            shuffled = [messages[i] for i in pos]
            rng.shuffle(shuffled)
            for i, m in zip(pos, shuffled):
                messages[i] = m
            reordered += 1
    out = B.Bench(messages=messages, queries=bench.queries, gazetteer=bench.gazetteer,
                  label=f"{bench.label}-reordered", chain_of=bench.chain_of)
    out.reordered_chains = reordered
    return out


CASES = ("subject", "third_party", "group", "missing")


def participants(bench: B.Bench, seed: int) -> B.Bench:
    """Reassign who each message was exchanged with. Queries keep the subject
    as P_t, so in the third-party and missing cases the fact the query needs
    was never observed in a conversation with that person."""
    rng = random.Random(seed)
    people = sorted({q.partner for q in bench.queries})
    case_of = {chain: CASES[i % len(CASES)]
               for i, chain in enumerate(sorted(set(bench.chain_of.values())))}
    messages = []
    for days_ago, partner, text in bench.messages:
        chain = bench.chain_of.get(text)
        case = case_of.get(chain, "subject") if isinstance(partner, str) else "subject"
        other = rng.choice([p for p in people if p != partner])
        messages.append((days_ago, {"subject": partner, "third_party": other,
                                    "group": (partner, other), "missing": ()}[case], text))
    queries = [B.Query(q.qid, q.partner, q.prefix, q.current, list(q.stale), list(q.wrong),
                       dict(q.meta, case=case_of.get(q.meta["chain"], "subject")))
               for q in bench.queries]
    return B.Bench(messages=messages, queries=queries, gazetteer=bench.gazetteer,
                   label=f"{bench.label}-participants", chain_of=bench.chain_of)
