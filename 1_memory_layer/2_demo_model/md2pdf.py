#!/usr/bin/env python3
"""Minimal Markdown -> PDF for this repo's docs (reportlab only, no pandoc/LaTeX).

Handles the constructs WRITEUP.md / EXAMPLES.md actually use: ATX headings,
paragraphs, bullet & numbered lists, blockquotes, pipe tables, horizontal rules,
and inline **bold** / *italic* / `code` / [text](url). Not a general Markdown
engine -- just enough to render these two files faithfully.

Usage: python3 md2pdf.py WRITEUP.md WRITEUP.pdf
"""

import html
import re
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable,
)

# ----------------------------- inline markup --------------------------------

_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_CODE = re.compile(r"`([^`]+)`")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITAL = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)")


def inline(text):
    """Markdown inline -> reportlab mini-HTML. Escape first, then re-introduce
    the tags we support (using placeholders so escaping can't touch them)."""
    # protect code spans (no inner markup) before escaping
    codes = []
    def _stash(m):
        codes.append(m.group(1))
        return f"\x00C{len(codes)-1}\x00"
    text = _CODE.sub(_stash, text)
    text = html.escape(text)
    text = _BOLD.sub(r"<b>\1</b>", text)
    text = _ITAL.sub(r"<i>\1</i>", text)
    text = _LINK.sub(r'<font color="#1a56db"><u>\1</u></font>', text)
    def _unstash(m):
        code = html.escape(codes[int(m.group(1))])
        return (f'<font face="Courier" size="8.5" backColor="#f0f0f0">'
                f'{code}</font>')
    text = re.sub(r"\x00C(\d+)\x00", _unstash, text)
    return text


# ------------------------------- styles -------------------------------------

def styles():
    ss = getSampleStyleSheet()
    base = ParagraphStyle("body", parent=ss["BodyText"], fontSize=9.5,
                          leading=13.5, spaceAfter=5, alignment=TA_LEFT)
    return {
        "body": base,
        "h1": ParagraphStyle("h1", parent=base, fontSize=17, leading=21,
                             spaceBefore=6, spaceAfter=9, textColor=colors.HexColor("#111")),
        "h2": ParagraphStyle("h2", parent=base, fontSize=13.5, leading=17,
                             spaceBefore=12, spaceAfter=6, textColor=colors.HexColor("#1a1a1a")),
        "h3": ParagraphStyle("h3", parent=base, fontSize=11, leading=15,
                             spaceBefore=8, spaceAfter=4, textColor=colors.HexColor("#1a1a1a")),
        "li": ParagraphStyle("li", parent=base, leftIndent=14, bulletIndent=4, spaceAfter=2),
        "quote": ParagraphStyle("quote", parent=base, leftIndent=10, textColor=colors.HexColor("#555"),
                                fontName="Helvetica-Oblique", borderPadding=(0, 0, 0, 6)),
        "cell": ParagraphStyle("cell", parent=base, fontSize=7.6, leading=10, spaceAfter=0),
        "cellh": ParagraphStyle("cellh", parent=base, fontSize=7.8, leading=10,
                                spaceAfter=0, fontName="Helvetica-Bold"),
    }


# ------------------------------- parsing ------------------------------------

def is_table_sep(line):
    return bool(re.match(r"^\s*\|?[\s:|-]+\|?\s*$", line)) and "-" in line


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    # split on unescaped pipes
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line)]


def build(md, S, avail_w):
    flow = []
    lines = md.splitlines()
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()

        # blank
        if not stripped:
            i += 1
            continue

        # horizontal rule
        if re.match(r"^(-{3,}|\*{3,}|_{3,})$", stripped):
            flow.append(Spacer(1, 3))
            flow.append(HRFlowable(width="100%", thickness=0.6,
                                   color=colors.HexColor("#ccc")))
            flow.append(Spacer(1, 3))
            i += 1
            continue

        # heading
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            lvl = min(len(m.group(1)), 3)
            flow.append(Paragraph(inline(m.group(2)), S[f"h{lvl}"]))
            i += 1
            continue

        # table: current line has a pipe and next line is a separator
        if "|" in line and i + 1 < n and is_table_sep(lines[i + 1]):
            header = split_row(line)
            rows = []
            i += 2
            while i < n and "|" in lines[i] and lines[i].strip():
                rows.append(split_row(lines[i]))
                i += 1
            flow.append(make_table(header, rows, S, avail_w))
            flow.append(Spacer(1, 6))
            continue

        # blockquote
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            flow.append(Paragraph(inline(" ".join(buf)), S["quote"]))
            continue

        # bullet / numbered list
        if re.match(r"^\s*([-*+]|\d+\.)\s+", line):
            while i < n and re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i]):
                lm = re.match(r"^\s*([-*+]|(\d+)\.)\s+(.*)$", lines[i])
                bullet = "•" if lm.group(2) is None else f"{lm.group(2)}."
                flow.append(Paragraph(inline(lm.group(3)), S["li"],
                                      bulletText=bullet))
                i += 1
            flow.append(Spacer(1, 3))
            continue

        # paragraph (gather until blank / block boundary)
        buf = [stripped]
        i += 1
        while i < n and lines[i].strip() and not re.match(
                r"^(#{1,6}\s|>|\s*([-*+]|\d+\.)\s|(-{3,}|\*{3,}|_{3,})$)", lines[i]) \
                and not ("|" in lines[i] and i + 1 < n and is_table_sep(lines[i + 1])):
            buf.append(lines[i].strip())
            i += 1
        flow.append(Paragraph(inline(" ".join(buf)), S["body"]))
    return flow


def make_table(header, rows, S, avail_w):
    ncol = max(len(header), *(len(r) for r in rows)) if rows else len(header)
    header += [""] * (ncol - len(header))
    data = [[Paragraph(inline(c), S["cellh"]) for c in header]]
    for r in rows:
        r = r + [""] * (ncol - len(r))
        data.append([Paragraph(inline(c), S["cell"]) for c in r])
    # equal columns, but give a narrow first column if it looks like an index/#
    col_w = [avail_w / ncol] * ncol
    if header[0].strip() in ("#", "No", "No.", "id"):
        col_w = [avail_w * 0.05] + [(avail_w * 0.95) / (ncol - 1)] * (ncol - 1)
    t = Table(data, colWidths=col_w, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef2ff")),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#cccccc")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#fafafa")]),
    ]))
    return t


def main():
    src, dst = sys.argv[1], sys.argv[2]
    md = open(src, encoding="utf-8").read()
    S = styles()
    margin = 16 * mm
    avail_w = A4[0] - 2 * margin
    doc = SimpleDocTemplate(dst, pagesize=A4, leftMargin=margin, rightMargin=margin,
                            topMargin=15 * mm, bottomMargin=15 * mm,
                            title=src.rsplit("/", 1)[-1])
    doc.build(build(md, S, avail_w))
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
