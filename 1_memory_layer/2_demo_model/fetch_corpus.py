#!/usr/bin/env python3
"""Build a long-term single-user writing corpus from public datasets.

Sources
-------
- Emails: the Berkeley "Enron with categories" subset (1,703 real Enron
  messages, public record). We keep only mail *written by one sender*
  (default: steven.kean@enron.com, the most prolific author in the subset),
  strip forwarded/quoted material, and sort chronologically -> a realistic
  timeline of one person's work email.
- Prose: a Project Gutenberg book (default: Pride and Prejudice, #1342),
  split into paragraphs -> the same "user" also writes long-form prose.

Output: data/user_corpus.json
  {"email": [{"date": iso, "subject": str, "text": str}, ...],   # chronological
   "prose": [str, ...]}                                          # in book order

Downloads are cached under data/raw/ and skipped when present.

Usage: python3 fetch_corpus.py [--sender steven.kean@enron.com] [--book 1342]
"""

from __future__ import annotations

import argparse
import email.utils
import json
import os
import re
import subprocess
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "data", "raw")
OUT = os.path.join(HERE, "data", "user_corpus.json")

ENRON_URL = "https://bailando.berkeley.edu/enron/enron_with_categories.tar.gz"
GUTENBERG_URL = "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt"

# Anything below these markers is forwarded/quoted, not the author's own text.
_QUOTE_MARKERS = [
    re.compile(r"-{5,}\s*Forwarded", re.I),
    re.compile(r"-{3,}\s*Original Message", re.I),
    re.compile(r"^\s*_{10,}\s*$", re.M),
    re.compile(r"^\s*From:\s", re.M),      # embedded reply header
    re.compile(r"^\s*To:\s.+@", re.M),
    # Lotus Notes reply attribution: "Eric Thode 08/22/2000 04:53 PM"
    re.compile(r"^.{0,60}\d{2}/\d{2}/\d{4} \d{2}:\d{2}(:\d{2})? ?(AM|PM)", re.M),
]


def _download(url: str, dest: str) -> None:
    if os.path.exists(dest):
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"[fetch] {url}")
    subprocess.run(["curl", "-sSL", "--fail", "--max-time", "120",
                    "-o", dest, url], check=True)


# ---------------------------------------------------------------------------
# Enron emails
# ---------------------------------------------------------------------------

def _parse_email(raw: str):
    head, sep, body = raw.partition("\n\n")
    if not sep:
        return None
    headers = {}
    for line in head.splitlines():
        m = re.match(r"([A-Za-z-]+):\s*(.*)", line)
        if m:
            headers[m.group(1).lower()] = m.group(2).strip()
    return headers, body


def _own_text(body: str) -> str:
    """Keep only the text the author typed: cut at the first quote/forward marker."""
    cut = len(body)
    for pat in _QUOTE_MARKERS:
        m = pat.search(body)
        if m:
            cut = min(cut, m.start())
    text = body[:cut]
    # unwrap hard-wrapped lines but keep paragraph breaks
    paras = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
    paras = [p for p in paras if p]
    return "\n\n".join(paras)


def build_email_corpus(sender: str, min_words: int, max_emails: int):
    tgz = os.path.join(RAW, "enron_with_categories.tar.gz")
    _download(ENRON_URL, tgz)
    root = os.path.join(RAW, "enron_with_categories")
    if not os.path.isdir(root):
        with tarfile.open(tgz) as tf:
            tf.extractall(RAW)

    seen = set()
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".txt") or fn == "categories.txt":
                continue
            with open(os.path.join(dirpath, fn), errors="replace") as f:
                parsed = _parse_email(f.read())
            if not parsed:
                continue
            headers, body = parsed
            if headers.get("from", "").lower() != sender:
                continue
            text = _own_text(body)
            words = text.split()
            if len(words) < min_words:
                continue
            key = " ".join(words[:25]).lower()
            if key in seen:            # the subset contains duplicates
                continue
            seen.add(key)
            try:
                ts = email.utils.parsedate_to_datetime(headers.get("date", ""))
            except (TypeError, ValueError):
                continue
            if ts is None or ts.year < 1995:   # zeroed/corrupt Date headers
                continue
            out.append({
                "date": ts.isoformat() if ts else "",
                "subject": headers.get("subject", ""),
                "text": text,
                "_ts": ts.timestamp(),
            })
    out.sort(key=lambda e: e["_ts"])
    for e in out:
        e.pop("_ts")
    return out[:max_emails]


# ---------------------------------------------------------------------------
# Gutenberg prose
# ---------------------------------------------------------------------------

def build_prose_corpus(book_id: int, min_words: int, max_words: int,
                       max_paras: int):
    path = os.path.join(RAW, f"pg{book_id}.txt")
    _download(GUTENBERG_URL.format(id=book_id), path)
    with open(path, errors="replace") as f:
        text = f.read()
    m = re.search(r"\*\*\* START OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text)
    if m:
        text = text[m.end():]
    m = re.search(r"\*\*\* END OF (?:THE|THIS) PROJECT GUTENBERG", text)
    if m:
        text = text[:m.start()]

    paras = []
    for block in re.split(r"\n\s*\n", text):
        p = re.sub(r"\s+", " ", block).strip()
        n = len(p.split())
        if n < min_words or n > max_words:
            continue
        if p.isupper() or p.startswith(("CHAPTER", "Chapter", "[Illustration")):
            continue
        paras.append(p)
        if len(paras) >= max_paras:
            break
    return paras


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sender", default="steven.kean@enron.com")
    ap.add_argument("--book", type=int, default=1342, help="Gutenberg book id")
    ap.add_argument("--min-email-words", type=int, default=25)
    ap.add_argument("--max-emails", type=int, default=250)
    ap.add_argument("--max-paras", type=int, default=120)
    args = ap.parse_args()

    emails = build_email_corpus(args.sender, args.min_email_words, args.max_emails)
    prose = build_prose_corpus(args.book, 40, 180, args.max_paras)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({
            "meta": {
                "email_source": ENRON_URL, "email_sender": args.sender,
                "prose_source": GUTENBERG_URL.format(id=args.book),
            },
            "email": emails,
            "prose": prose,
        }, f, indent=1)

    ew = sum(len(e["text"].split()) for e in emails)
    pw = sum(len(p.split()) for p in prose)
    print(f"[corpus] {len(emails)} emails ({ew} words) by {args.sender}, "
          f"{emails[0]['date'][:10]} .. {emails[-1]['date'][:10]}")
    print(f"[corpus] {len(prose)} prose paragraphs ({pw} words) from pg{args.book}")
    print(f"[corpus] -> {OUT}")


if __name__ == "__main__":
    main()
