"""Rule extractors.

make_rule_extractor   keyless sentence-level facts with entity sets
make_keyed_extractor  adds an (entity, slot) key when a sentence names a
                      gazetteer entity, a slot noun, and a value of the
                      slot's type (or a cancellation marker)
strip_keys            same drafts, keys removed (the keyless control arm)
with_key_noise        injects missed merges (rate p) and false merges (rate q)
"""

from __future__ import annotations

import random
import re
from typing import Callable, Iterable, List

from pfm import STOPWORDS, Draft

Extractor = Callable[[str], List[Draft]]

_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+|\n+")
_DATE = re.compile(r"\b\d{4}-\d{1,2}-\d{1,2}\b"
                   r"|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b")
_CAPSEQ = re.compile(r"\b[A-Z][\w\-]*(?:\s+[A-Z][\w\-]*)*")
_SIGNAL = re.compile(r"\b(?:will|agreed|decided|due|deadline|scheduled|moved|confirmed|"
                     r"prefers?|is|are|was|needs?|owns?|sent|meeting)\b", re.I)


def sentences(text: str) -> Iterable[str]:
    for s in _SENT_SPLIT.split(text):
        s = s.strip()
        if 8 <= len(s) <= 300:
            yield s


def make_rule_extractor(gazetteer: Iterable[str]) -> Extractor:
    """Keep sentences that have an anchor (entity or digit) and a factual verb."""
    gaz = [g.lower() for g in gazetteer]

    def extract(text: str) -> List[Draft]:
        out = []
        for s in sentences(text):
            ents = {m.group(0).lower() for m in _DATE.finditer(s)}
            ents |= {m.group(0).lower() for m in _CAPSEQ.finditer(s)
                     if m.group(0).lower() not in STOPWORDS}
            low = s.lower()
            ents |= {g for g in gaz if g in low}
            if (ents or any(c.isdigit() for c in s)) and _SIGNAL.search(s):
                out.append(Draft(s, tuple(sorted(ents))))
        return out

    return extract


# A slot claims a sentence only when its noun family AND its value type are
# present: noun families overlap ("standup" is both a meeting and a room noun).
_TIME = r"\b\d{1,2}:\d{2}\s?(?:am|pm)\b"
_ISO = r"\b\d{4}-\d{2}-\d{2}\b"
_MONDATE = r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}\b"
SLOT_PATTERNS = {                       # order matters: room claims before meeting
    "room": (r"\b(?:standup|sync|planning call|review|room|location)\b",
             r"\broom\s+\d{1,2}[A-F]\b"),
    "meeting": (r"\b(?:standup|sync|planning call|review|1:1|check-?in)\b", _TIME),
    "deadline": (r"\b(?:deadline|due date)\b", f"(?:{_MONDATE}|{_ISO})"),
    "launch": (r"\b(?:launch|cutover|release)\b", f"(?:{_ISO}|{_MONDATE})"),
    "rate": (r"\b(?:day rate|hourly rate)\b", r"\$\d[\d,]*\b(?!k)"),
    "budget": (r"\b(?:budget cap|budget)\b", r"\$\d[\d,]*k\b"),
}
_SLOTS = {n: (re.compile(a, re.I), re.compile(b, re.I)) for n, (a, b) in SLOT_PATTERNS.items()}
_CANCEL = re.compile(r"\b(?:cancell?ed|called off|scrapped)\b", re.I)
CANCELLABLE = ("meeting", "deadline")


def detect_slot(sentence: str):
    """Returns (slot, noun) or (None, None)."""
    for name, (noun, value) in _SLOTS.items():
        m = noun.search(sentence)
        if m and value.search(sentence):
            return name, m.group(0).lower()
    if _CANCEL.search(sentence):
        for name in CANCELLABLE:
            m = _SLOTS[name][0].search(sentence)
            if m:
                return name, m.group(0).lower()
    return None, None


def make_keyed_extractor(gazetteer: Iterable[str], granularity: str = "slot") -> Extractor:
    """granularity: "slot" keys by (entity, slot); "noun" keys by (entity,
    slot:noun), which keeps two instances of one slot type apart."""
    base = make_rule_extractor(gazetteer)
    gaz = sorted({g.lower() for g in gazetteer}, key=len, reverse=True)

    def extract(text: str) -> List[Draft]:
        out = []
        for s in sentences(text):
            low = s.lower()
            ent = next((g for g in gaz if g in low), None)
            slot, noun = detect_slot(s)
            drafts = base(s)
            if ent and slot:
                key = (ent, slot if granularity == "slot" else f"{slot}:{noun}")
                out.append(Draft(s, drafts[0].entities if drafts else (ent,), key))
            else:
                out.extend(drafts)
        return out

    return extract


def strip_keys(extractor: Extractor) -> Extractor:
    return lambda text: [Draft(d.text, d.entities) for d in extractor(text)]


def with_key_noise(extractor: Extractor, p_miss: float, q_false: float, seed: int) -> Extractor:
    """Corrupt keys, deterministically per (seed, sentence).

    missed merge (p): the draft gets a fresh key of its own, so it cannot
                      supersede, or be superseded by, the rest of its chain
    false merge  (q): the draft takes the key of another entity's slot of the
                      same type seen earlier, closing that slot's active value
    `extract.log` counts realized corruptions.
    """
    seen: dict = {}                                   # slot -> keys seen so far

    def extract(text: str) -> List[Draft]:
        out = []
        for d in extractor(text):
            if d.key is None:
                out.append(d)
                continue
            rng = random.Random(f"{seed}:{d.text}")
            key, pool = d.key, [k for k in seen.get(d.key[1], ()) if k[0] != d.key[0]]
            u = rng.random()
            if u < p_miss:
                key = (d.key[0], f"{d.key[1]}#miss{extract.log['miss']}")
                extract.log["miss"] += 1
            elif u < p_miss + q_false and pool:
                key = rng.choice(sorted(pool))
                extract.log["false"] += 1
            seen.setdefault(d.key[1], set()).add(d.key)
            extract.log["keyed"] += 1
            out.append(Draft(d.text, d.entities, key))
        return out

    extract.log = {"keyed": 0, "miss": 0, "false": 0}
    return extract


def make_open_extractor(min_chars: int = 20) -> Extractor:
    """No domain rules: every sentence of an observation becomes a draft, with
    capitalized sequences and dates as its entities. The rule extractor above
    needs a signal verb and an anchor, which a template corpus supplies and
    ordinary conversation does not; on LongMemEval it keeps 0.29 sentences per
    turn, so the corpora we did not write are ingested with this instead."""

    def extract(text: str) -> List[Draft]:
        out = []
        for s in sentences(text):
            if len(s) < min_chars:
                continue
            ents = {m.group(0).lower() for m in _DATE.finditer(s)}
            ents |= {m.group(0).lower() for m in _CAPSEQ.finditer(s)
                     if m.group(0).lower() not in STOPWORDS and len(m.group(0)) > 2}
            out.append(Draft(s, tuple(sorted(ents))))
        return out

    return extract
