"""Key-emitting rule extractor: (entity, slot) keys enable end-to-end
bitemporal supersession (paper task: 'temporal correctness first').

A sentence yields a keyed draft when it names a gazetteer entity, mentions
a mutable-slot noun, and carries a value (time / date / money / room code)
or a cancellation marker. Everything else falls through to the stock rule
extractor, so non-slot factual coverage is unchanged.

`strip_keys` wraps any extractor into its keyless twin — used as the
control arm so the *only* difference between arms is supersession, not
extraction recall.
"""

from __future__ import annotations

import re
from typing import Callable, List

import common  # ensures 5_dpfm on sys.path
import dpfm

# A slot claims a sentence only when BOTH its noun family AND its value
# type are present. Noun families overlap across slots (e.g. "standup"
# appears in both meeting-time and meeting-room sentences), so noun-only
# detection assigns wrong keys and supersedes across unrelated slots —
# measured as label_reachable dropping below the keyless arm.
_TIME = r"\b\d{1,2}:\d{2}\s?(?:am|pm)\b"
_ISO = r"\b\d{4}-\d{2}-\d{2}\b"
_MONDATE = r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}\b"
_MONEY = r"\$\d[\d,]*\b(?!k)"
_MONEYK = r"\$\d[\d,]*k\b"
_ROOM = r"\broom\s+\d{1,2}[A-F]\b"

SLOT_SPECS = {
    # order matters: value-specific slots claim their sentences first
    "room":     (r"\b(?:standup|sync|planning call|review|room|location)\b", _ROOM),
    "meeting":  (r"\b(?:standup|sync|planning call|review|1:1|check-?in)\b", _TIME),
    "deadline": (r"\b(?:deadline|due date)\b", f"(?:{_MONDATE}|{_ISO})"),
    "launch":   (r"\b(?:launch|cutover|release)\b", f"(?:{_ISO}|{_MONDATE})"),
    "rate":     (r"\b(?:day rate|hourly rate)\b", _MONEY),
    "budget":   (r"\b(?:budget cap|budget)\b", _MONEYK),
}
SLOT_RES = {name: (re.compile(noun, re.I), re.compile(val, re.I))
            for name, (noun, val) in SLOT_SPECS.items()}

VALUE_RES = [re.compile(p, re.I)
             for p in (_TIME, _ISO, _MONDATE, _MONEY, _MONEYK, _ROOM)]
CANCEL_RE = re.compile(r"\b(?:cancell?ed|called off|scrapped)\b", re.I)


def detect_slot(sentence: str):
    """Noun family + value type must both match; a cancellation (which has
    no value) falls back to the cancellable slots by noun."""
    for name, (noun_re, val_re) in SLOT_RES.items():
        if noun_re.search(sentence) and val_re.search(sentence):
            return name
    if CANCEL_RE.search(sentence):
        for name in ("meeting", "deadline"):
            if SLOT_RES[name][0].search(sentence):
                return name
    return None


def make_keyed_extractor(gazetteer) -> Callable[[str], List[dpfm.FactDraft]]:
    base = dpfm.make_rule_extractor(gazetteer=gazetteer)
    gaz_low = sorted({g.lower() for g in gazetteer}, key=len, reverse=True)

    def extract(text: str) -> List[dpfm.FactDraft]:
        drafts: List[dpfm.FactDraft] = []
        for sent in dpfm._SENT_SPLIT_RE.split(text):
            s = sent.strip()
            if not 8 <= len(s) <= 300:
                continue
            low = s.lower()
            ent = next((g for g in gaz_low if g in low), None)
            slot = detect_slot(s)
            base_drafts = base(s)
            if ent and slot:
                ents = base_drafts[0].entities if base_drafts else (ent,)
                drafts.append(dpfm.FactDraft(text=s, entities=ents,
                                             key=(ent, slot)))
            else:
                drafts.extend(base_drafts)
        return drafts

    return extract


def strip_keys(extractor) -> Callable[[str], List[dpfm.FactDraft]]:
    """Keyless twin: identical sentence coverage, no supersession."""
    def extract(text: str) -> List[dpfm.FactDraft]:
        return [dpfm.FactDraft(text=d.text, entities=d.entities, kind=d.kind,
                               key=None) for d in extractor(text)]
    return extract
