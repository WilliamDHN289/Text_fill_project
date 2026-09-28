"""Public corpora, turned into the same Bench the synthetic generator emits.

Two axes of the taxonomy survive the move to text we did not write.

LongMemEval (knowledge-update)  carries the staleness axis. Its 78
    knowledge-update questions each have two annotated answer-bearing user
    turns, an earlier one stating a value that was later revised and a later
    one stating the value in force. We turn those annotations into exact
    labels by asking a local model for the verbatim span of each turn that
    answers the question and keeping only spans that occur in their turn
    word for word and differ from each other, so exposure stays a string
    check rather than a judgment. Every user turn of the corpus is ingested,
    so the 78 queries are answered against 5.5k turns of other people's
    conversations. The corpus is single-user, so it says nothing about
    identity.

LoCoMo  carries the misattribution axis, because the name John belongs to a
    speaker in three of its ten conversations. Over one store built from all
    ten, a block that answers a question about one John with a fact from
    another John's conversation is a misattribution, and provenance settles
    that without any value label. The same corpus, split back into
    per-conversation stores, gives unanswerable queries for free: a question
    from another conversation has no answer in this one.

`fetch.sh` downloads both files into `data/`.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import benchmark as B

DATA = Path(__file__).resolve().parent / "data"
LME = DATA / "longmemeval_oracle.json"
LOCOMO = DATA / "locomo10.json"

SPAN_PROMPT = (
    "Question: {q}\n\nMessage the user wrote earlier:\n\"{t}\"\n\n"
    "Copy the exact words from the message that answer the question at the time it was "
    "written. Reply with that span only, at most 8 words, copied verbatim, no quotes and "
    "no explanation. If the message does not answer the question, reply NONE.")
MAX_SPAN_TOKENS = 10


def _days_ago(stamp: str, now: str) -> float:
    """LongMemEval dates look like '2023/05/25 (Thu) 20:21'."""
    import datetime as dt
    fmt = lambda s: dt.datetime.strptime(re.sub(r"\s*\([A-Za-z]+\)", "", s), "%Y/%m/%d %H:%M")
    return max(0.0, (fmt(now) - fmt(stamp)).total_seconds() / B.DAY)


def _usable(span: str, turn: str) -> bool:
    return (bool(span) and span.upper() != "NONE" and len(span.split()) <= MAX_SPAN_TOKENS
            and B.contains(turn, span))


def longmemeval(ask, path: Path = LME, distractors: int = 0,
                seed: int = 7) -> Tuple[B.Bench, dict]:
    """`ask(prompt) -> str` is the labelling model, called once per answer-bearing
    turn and expected to be cached by the caller.

    `distractors` caps how many of the other 422 questions contribute their
    sessions to the corpus. Assigning an open-domain key costs a model call
    per turn, so the full 5,479-turn corpus is out of reach on one laptop
    GPU; the cap keeps the store in the low thousands of facts and is
    reported with the results."""
    import random
    data = json.loads(path.read_text())
    now = max(e["question_date"] for e in data)
    ku = [e for e in data if e["question_type"] == "knowledge-update"]
    rest = [e for e in data if e["question_type"] != "knowledge-update"]
    if distractors:
        rest = random.Random(seed).sample(rest, min(distractors, len(rest)))
    data = ku + rest
    messages, queries, chain_of, audit = [], [], {}, []
    for e in data:
        dates = eval(e["haystack_dates"]) if isinstance(e["haystack_dates"], str) \
            else e["haystack_dates"]
        for sess, date in zip(e["haystack_sessions"], dates):
            for turn in sess:
                if turn.get("role") == "user":
                    text = turn["content"].strip()
                    messages.append((_days_ago(date, now), "user", text))
                    chain_of.setdefault(text, e["question_id"])

    for e in data:
        if e["question_type"] != "knowledge-update":
            continue
        turns = [t["content"].strip() for s in e["haystack_sessions"] for t in s
                 if t.get("role") == "user" and t.get("has_answer")]
        if len(turns) < 2:
            audit.append({"qid": e["question_id"], "drop": "fewer than two answer turns"})
            continue
        old, new = turns[0], turns[-1]
        spans = [ask(SPAN_PROMPT.format(q=e["question"], t=t)).strip().strip('"')
                 for t in (old, new)]
        row = {"qid": e["question_id"], "question": e["question"], "gold": str(e["answer"]),
               "old_span": spans[0], "new_span": spans[1]}
        if not (_usable(spans[0], old) and _usable(spans[1], new)):
            audit.append({**row, "drop": "span missing or not verbatim"})
            continue
        if B.canon(spans[0]) == B.canon(spans[1]) or B.contains(spans[1], spans[0]):
            audit.append({**row, "drop": "superseded span not distinct"})
            continue
        audit.append({**row, "drop": ""})
        queries.append(B.Query(
            qid=e["question_id"], partner="user", prefix=e["question"],
            current=spans[1], stale=[spans[0]], wrong=[],
            meta=dict(chain=e["question_id"], slot="knowledge-update", revisions=1,
                      verbatim=False, cancel=False, ambiguous=False, q_level=0,
                      age_days=0.0, distractors=0, corpus="longmemeval")))
    messages.sort(key=lambda m: -m[0])
    bench = B.Bench(messages=messages, queries=queries, gazetteer=[], label="longmemeval",
                    chain_of=chain_of)
    kept = sum(not a["drop"] for a in audit)
    return bench, {"audit": audit, "questions": len(audit), "labelled": kept,
                   "user_turns": len(messages), "distractor_questions": len(rest)}


# --------------------------------------------------------------------------
# LoCoMo
# --------------------------------------------------------------------------

def _locomo_turns(conv: dict) -> List[Tuple[str, str, str]]:
    """(session date, speaker, text) for every dialogue turn, in session order."""
    out = []
    for i in range(1, 100):
        sess = conv.get(f"session_{i}")
        if not sess:
            continue
        date = conv.get(f"session_{i}_date_time", "")
        out += [(date, t["speaker"], t["text"]) for t in sess]
    return out


def _locomo_date(stamp: str, base: float) -> float:
    """LoCoMo stamps look like '1:56 pm on 8 May, 2023'; we only need an order,
    so unparsed stamps fall back to the running counter the caller supplies."""
    import datetime as dt
    m = re.search(r"(\d{1,2}) (\w+), (\d{4})", stamp or "")
    if not m:
        return base
    try:
        return (dt.datetime(2024, 1, 1) - dt.datetime.strptime(
            f"{m[1]} {m[2][:3]} {m[3]}", "%d %b %Y")).days
    except ValueError:
        return base


def locomo(path: Path = LOCOMO, collide: str = "John",
           categories: Tuple[int, ...] = (1, 2, 4)) -> Tuple[B.Bench, dict]:
    """One store over all ten conversations. A query is a question whose gold
    answer occurs verbatim in its own conversation; `owner` records which
    conversation that is, and `rivals` the conversations whose speakers share
    the queried first name. Misattribution is then provenance, not a label."""
    data = json.loads(path.read_text())
    convs, messages, chain_of = [], [], {}
    for ci, item in enumerate(data):
        conv = item["conversation"]
        speakers = (conv["speaker_a"], conv["speaker_b"])
        turns = _locomo_turns(conv)
        convs.append({"i": ci, "speakers": speakers, "text": " ".join(t for _, _, t in turns)})
        for j, (date, speaker, text) in enumerate(turns):
            text = f"{speaker}: {text.strip()}"      # the speaker is part of the record
            messages.append((_locomo_date(date, 400 - ci * 30 - j * 0.01), speaker, text))
            chain_of.setdefault(text, f"c{ci}")

    rivals = {ci: [o["i"] for o in convs if o["i"] != ci
                   and set(n.split()[0] for n in o["speakers"])
                   & set(n.split()[0] for n in convs[ci]["speakers"])]
              for ci in range(len(convs))}
    queries, skipped = [], 0
    for ci, item in enumerate(data):
        for qi, qa in enumerate(item["qa"]):
            if qa.get("category") not in categories:
                continue
            gold = str(qa.get("answer", "")).strip()
            if not gold or len(gold.split()) > MAX_SPAN_TOKENS \
                    or not B.contains(convs[ci]["text"], gold):
                skipped += 1
                continue
            queries.append(B.Query(
                qid=f"locomo-c{ci}-q{qi}", partner=item["conversation"]["speaker_a"],
                prefix=qa["question"], current=gold, stale=[], wrong=[],
                meta=dict(chain=f"c{ci}", slot=f"cat{qa['category']}", revisions=0,
                          verbatim=False, cancel=False,
                          ambiguous=bool(rivals[ci]), q_level=0, age_days=0.0,
                          distractors=0, corpus="locomo", owner=f"c{ci}",
                          rivals=[f"c{r}" for r in rivals[ci]],
                          collide=collide in " ".join(convs[ci]["speakers"]))))
    messages.sort(key=lambda m: -m[0])
    bench = B.Bench(messages=messages, queries=queries, gazetteer=[], label="locomo",
                    chain_of=chain_of)
    return bench, {"conversations": len(convs), "turns": len(messages),
                   "queries": len(queries), "skipped_no_verbatim_answer": skipped,
                   "name_sharing_conversations": {str(k): v for k, v in rivals.items() if v}}


