"""Controlled update benchmark.

Generates revision chains over (entity, mutable slot) pairs and labeled
message-prefix queries, varying:

  person / project        (incl. shared-first-name pairs -> identity ambiguity)
  mutable slot            meeting / deadline / launch / rate / budget / room
  number of revisions     0..4
  paraphrasing            3 message templates x 2 query templates
  verbatim revisions      same template, only the value changes (dedup trap)
  replacement vs cancellation
  fact age, distractor load, corpus size (filler count)

Chain i yields two queries (both query templates) when i is even and one
when i is odd, so 160 chains give 240 queries. Every value token is globally unique (registry), so exposure metrics are
exact substring checks after `canon()` normalization. Labels per query:
  current  — the value a correct completion must contain
  stale    — all superseded values of the chain
  wrong    — current values of same-slot chains owned by a *different*
             entity that shares the query's surface form (first name)
Metrics downstream: current-fact recall, stale exposure, co-injection
(current AND stale both in the prompt), wrong-person exposure,
clean-correct (current, no stale, no wrong).
"""

from __future__ import annotations

import random
import re
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple

DAY = 86_400.0
BASE = 1_750_000_000.0                  # logical "now" of every query

PEOPLE = [
    "Alex Chen", "Alex Rivera",        # ambiguous pair 1
    "Maya Patel", "Maya Song",         # ambiguous pair 2
    "Jordan Fox", "Jordan Lindt",      # ambiguous pair 3
    "Dana Wolf", "Dana Okafor",        # ambiguous pair 4
    "Robin Hale", "Robin Castro",      # ambiguous pair 5
    "Sasha Bell", "Sasha Moreau",      # ambiguous pair 6
    "Priya Nair", "Tom Walsh", "Elena Ruiz", "Sam Iqbal",
    "Leo Marchetti", "Grace Obi", "Hana Sato", "Marco Deluca",
    "Nia Brooks", "Owen Reid", "Farah Aziz", "Kai Nakamura",
    "Ines Farkas", "Callum Doyle", "Ruth Ellison", "Yusuf Demir",
    "Petra Novak", "Silas Grant", "Tessa Byrne", "Viktor Larsen",
    "Wren Ashford", "Zane Holloway", "Amara Diallo", "Bram Visser",
]
PROJECTS = ["Halcyon", "Bluebird", "Orion", "Sable", "Vega", "Juniper",
            "Cobalt", "Ember", "Foxglove", "Granite", "Iris", "Krait",
            "Lumen", "Mistral", "Nimbus", "Onyx", "Pampas", "Quartz",
            "Rowan", "Sirocco"]
AMBIG_N = 12                            # first 12 people = 6 ambiguous pairs

CHITCHAT = [
    "Sounds good, talk later!", "Haha nice, thanks a lot!", "Perfect, thanks!",
    "Can you resend that?", "No worries at all.", "Great, appreciate it!",
    "Sure thing, ping me anytime.", "Got it, thanks so much.", "Awesome news!",
    "Talk tomorrow?", "Safe travels!", "Congrats again on the demo!",
]

_MONTHS = {"january": "jan", "february": "feb", "march": "mar", "april": "apr",
           "may": "may", "june": "jun", "july": "jul", "august": "aug",
           "september": "sep", "october": "oct", "november": "nov",
           "december": "dec"}


def canon(s: str) -> str:
    """Normalization for exposure/judging: case, month names, digit commas,
    am/pm spacing, whitespace."""
    s = s.lower()
    for full, abbr in _MONTHS.items():
        s = re.sub(rf"\b{full}\b", abbr, s)
    s = re.sub(r"(\d),(\d)", r"\1\2", s)
    s = re.sub(r"(\d)\s+(am|pm)\b", r"\1\2", s)
    s = re.sub(r"\s+", " ", s)
    return s


MONTH_ABBR = tuple(_MONTHS.values())


def value_pattern(value: str) -> str:
    """A regex for the ways a value gets respelled: 9:30am as 9:30 A.M.,
    Jun 3 as June 3rd, $1859 as $1,859."""
    parts = []
    for tok in re.findall(r"\d+|[A-Za-z]+|[^\sA-Za-z0-9]", value):
        if tok.isdigit():
            parts.append(",?".join(tok) + r"(?:st|nd|rd|th)?")
        elif tok.lower() in ("am", "pm"):
            parts.append(tok[0] + r"\.?\s?" + tok[1] + r"\.?")
        elif tok.isalpha() and tok.lower()[:3] in MONTH_ABBR:
            parts.append(tok[:3] + r"[a-z]*\.?")
        else:
            parts.append(re.escape(tok))
    return r"\s*".join(parts)


def mentions(text: str, value: str) -> bool:
    """Containment, allowing respellings and the month-day spellings of an ISO
    date ("October 17, 2026"). Used to judge generated text; stored facts are
    canonical, so exposure metrics use `contains`."""
    forms = [value]
    iso = re.fullmatch(r"\d{4}-(\d{2})-(\d{2})", value)
    if iso:
        mon, day = MONTH_ABBR[int(iso[1]) - 1], int(iso[2])
        forms += [f"{mon} {day}", f"{day} {mon}", f"{day} of {mon}"]
    return any(contains(text, f) or re.search(value_pattern(f), text, re.I) for f in forms)


def contains(hay: str, needle: str) -> bool:
    """Whole-token containment after canon(): "Dec 2" does not match "Dec 24"."""
    return re.search(rf"(?<!\w){re.escape(canon(needle))}(?!\w)", canon(hay)) is not None


@dataclass
class Query:
    qid: str
    partner: str
    prefix: str
    current: str                      # value token a correct completion copies
    stale: List[str]
    wrong: List[str]
    meta: Dict = field(default_factory=dict)


@dataclass
class Bench:
    messages: List[Tuple[float, str, str]]   # (days_ago, participant, text)
    queries: List[Query]
    gazetteer: List[str]
    label: str
    chain_of: Dict[str, int] = field(default_factory=dict)   # message text -> chain


# ------------------------------ value pools -------------------------------

class ValuePool:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.used: Set[str] = set()

    def _fresh(self, gen) -> str:
        for _ in range(2000):
            v = gen()
            if canon(v) not in self.used:
                self.used.add(canon(v))
                return v
        raise RuntimeError("value pool exhausted")

    def time(self):
        return self._fresh(lambda: f"{self.rng.randint(1, 11)}:"
                                   f"{self.rng.randint(1, 11) * 5:02d}"
                                   f"{self.rng.choice(['am', 'pm'])}")

    def date(self):
        return self._fresh(lambda: f"{self.rng.choice(list(_MONTHS.values())).capitalize()} "
                                   f"{self.rng.randint(1, 28)}")

    def iso(self):
        return self._fresh(lambda: f"2026-{self.rng.randint(8, 12):02d}-"
                                   f"{self.rng.randint(1, 28):02d}")

    def money(self):
        return self._fresh(lambda: f"${self.rng.randint(101, 1980)}")

    def moneyk(self):
        return self._fresh(lambda: f"${self.rng.randint(105, 480)}k")

    def room(self):
        return self._fresh(lambda: f"room {self.rng.randint(1, 19)}"
                                   f"{self.rng.choice('ABCDEF')}")


# ------------------------- slot / template config -------------------------

SLOTS = {
    # slot: (entity kind, nouns, value fn name, msg templates L0-2, query templates q0-1)
    "meeting": ("person", ["standup", "sync", "planning call"], "time",
                ["The {noun} with {ent} is moved to {v}.",
                 "{ent} {noun} is rescheduled to {v}.",
                 "New time for the {noun} with {ent}: moved to {v}."],
                ["Reminder — the {noun} with {first} is at ",
                 "Just confirming, {first} {noun} is now at "]),
    "deadline": ("person", ["deadline", "due date"], "date",
                 ["The {noun} for {ent} is moved to {v}.",
                  "{ent} agreed the {noun} is now {v}.",
                  "Heads up: {ent} {noun} moved, new date {v}."],
                 ["The {noun} for {first} is ",
                  "Quick check — {first} {noun} is now "]),
    "launch": ("project", ["launch", "cutover"], "iso",
               ["The {ent} {noun} is scheduled for {v}.",
                "{ent} {noun} moved to {v}.",
                "Confirmed: {ent} {noun} is now {v}."],
               ["The {ent} {noun} is scheduled for ",
                "As planned, {ent} {noun} lands on "]),
    "rate": ("person", ["day rate"], "money",
             ["{ent} confirmed the {noun} is {v}.",
              "The {noun} for {ent} moved to {v}.",
              "{ent} agreed: {noun} is now {v}."],
             ["{first}'s {noun} is ",
              "The agreed {noun} for {first} is "]),
    "budget": ("project", ["budget cap"], "moneyk",
               ["The {ent} {noun} is {v}.",
                "{ent} {noun} moved to {v}.",
                "We agreed the {ent} {noun} is now {v}."],
               ["The {noun} for {ent} is ",
                "Our {ent} {noun} is "]),
    "room": ("person", ["standup", "review"], "room",
             ["The {noun} with {ent} is moved to {v}.",
              "{ent} {noun} relocated, meeting location is {v}.",
              "The {noun} with {ent} is now in {v}."],
             ["The {noun} with {first} is in ",
              "Reminder, {first} {noun} moved to "]),
}

CANCEL_TPL = "The {noun} with {ent} is cancelled."
CANCEL_SLOTS = ("meeting", "deadline")


def fillers(n: int) -> List[Tuple[float, str, str]]:
    names = ["Sam Torres", "Nina Patel", "Omar Haddad", "Lucy Zhang",
             "Raj Mehta", "Ivy Novak", "Theo Brandt", "Mia Costa"]
    tpl = [("Jira Bot", "Ticket QA-{a} is assigned to {n}."),
           ("Deploy Bot", "Build {b} was deployed to staging."),
           ("Ops Board", "Server rack R{c} needs a firmware update."),
           ("Inventory Desk", "License seat L-{d} is reserved for {n}.")]
    out = []
    for i in range(n):
        w, t = tpl[i % 4]
        out.append((float(i % 28 + 1), w,
                    t.format(a=3000 + i, b=5200 + i, c=100 + i, d=900 + i,
                             n=names[i % 8])))
    return out


# ------------------------------ generator ---------------------------------

def generate(n_chains: int, seed: int, n_fillers: int, p_cancel: float,
             rev_weights: Dict[int, float], label: str) -> Bench:
    rng = random.Random(seed)
    pool = ValuePool(rng)
    slot_names = list(SLOTS)
    revs_pop, revs_w = zip(*rev_weights.items())

    person_slots = [s for s, spec in SLOTS.items() if spec[0] == "person"]
    used_keys = set()                    # (entity, slot) unique per chain —
                                         # shared keys would supersede across
                                         # chains and corrupt the labels
    chains = []
    for i in range(n_chains):
        if i < AMBIG_N:
            # engineered identity ambiguity: both members of a pair get a
            # chain on the SAME slot (keys differ — full names differ — but
            # the query's first-name surface form collides)
            ent = PEOPLE[i]
            slot = person_slots[(i // 2) % len(person_slots)]
        else:
            ent = slot = None
            for off in range(len(slot_names)):
                s = slot_names[(i + off) % len(slot_names)]
                pool_e = PEOPLE if SLOTS[s][0] == "person" else PROJECTS
                cands = [e for e in pool_e if (e, s) not in used_keys]
                if cands:
                    ent, slot = rng.choice(cands), s
                    break
            if ent is None:
                raise RuntimeError(
                    f"(entity, slot) pairs exhausted at chain {i}; "
                    f"reduce n_chains or extend PEOPLE/PROJECTS")
        used_keys.add((ent, slot))
        kind, nouns, vfn, mtpl, qtpl = SLOTS[slot]
        r = rng.choices(revs_pop, revs_w)[0]
        verbatim = (i % 10 == 7) and r >= 1
        cancel = (slot in CANCEL_SLOTS and r >= 1
                  and rng.random() < p_cancel)
        noun = rng.choice(nouns)
        start = rng.uniform(8, 27)
        ages = sorted([rng.uniform(0.3, start - 0.5) for _ in range(r)],
                      reverse=True)
        ages = [start] + ages                       # r+1 messages, oldest first
        values = [getattr(pool, vfn)() for _ in range(r + 1)]
        partner = ent if kind == "person" else rng.choice(PEOPLE)
        msgs = []
        for j, (age, v) in enumerate(zip(ages, values)):
            if cancel and j == r:
                text = CANCEL_TPL.format(noun=noun, ent=ent)
            else:
                lvl = 0 if verbatim else (i + j) % 3
                text = mtpl[lvl].format(noun=noun, ent=ent, v=v)
            msgs.append((age, partner, text))
        current = "cancelled" if cancel else values[-1]
        stale = values[:-1] if not cancel else values
        chains.append(dict(i=i, slot=slot, kind=kind, ent=ent, noun=noun,
                           partner=partner, msgs=msgs, current=current,
                           stale=stale, revisions=r, verbatim=verbatim,
                           cancel=cancel, qtpl=qtpl,
                           age=ages[-1]))

    # wrong-person sets: same slot, different entity, shared first name
    for c in chains:
        first = c["ent"].split()[0]
        c["wrong"] = [o["current"] for o in chains
                      if o["slot"] == c["slot"] and o["ent"] != c["ent"]
                      and o["kind"] == c["kind"] == "person"
                      and o["ent"].split()[0] == first
                      and o["current"] != "cancelled"]
        c["ambiguous"] = bool(c["wrong"])

    queries = []
    for c in chains:
        first = c["ent"].split()[0]
        n_q = 2 if c["i"] % 2 == 0 else 1          # paraphrase-variant query
        for q in range(n_q):
            prefix = c["qtpl"][q].format(noun=c["noun"], ent=c["ent"],
                                         first=first)
            queries.append(Query(
                qid=f"{label}-c{c['i']}-q{q}", partner=c["partner"], prefix=prefix, current=c["current"],
                stale=list(c["stale"]), wrong=list(c["wrong"]),
                meta=dict(chain=c["i"], slot=c["slot"], revisions=c["revisions"],
                          verbatim=c["verbatim"], cancel=c["cancel"],
                          ambiguous=c["ambiguous"], q_level=q,
                          age_days=round(c["age"], 1),
                          distractors=sum(1 for o in chains
                                          if o["slot"] == c["slot"]
                                          and o["i"] != c["i"]))))

    messages = [m for c in chains for m in c["msgs"]]
    messages += fillers(n_fillers)
    for i, t in enumerate(CHITCHAT):
        messages.append((float(i % 28 + 1), rng.choice(PEOPLE), t))
    messages.sort(key=lambda m: -m[0])

    gaz = PEOPLE + PROJECTS
    return Bench(messages=messages, queries=queries, gazetteer=gaz, label=label,
                 chain_of={m[2]: c["i"] for c in chains for m in c["msgs"]})


def wilson(k: int, n: int, z: float = 1.96) -> Tuple[float, float, float]:
    """rate and 95% Wilson interval."""
    if n == 0:
        return float("nan"), float("nan"), float("nan")
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5)
    return p, (c - h) / d, (c + h) / d
