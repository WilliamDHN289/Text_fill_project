"""User habit texts for DPHM cold-path training.

These simulate Daniel's long-term writing habits — recurring email phrases,
sign-offs, and domain terms that the base LM may miss but personal memory
should surface (e.g. signing as Daniel, not Chris).
"""

DEFAULT = [
    # sign-off habit — the key failure case in the email passage
    "Best,\nDaniel",
    "Thanks again for putting this together.\n\nBest,\nDaniel",
    "Let me know if you have any questions.\n\nBest,\nDaniel",
    # recurring work-email collocations
    "the quarterly report is in good shape",
    "the marketing spend went up in March",
    "a few people asked about that last quarter",
    "double check the numbers in the table on page four",
    "hop on a quick call to walk through the changes",
    "review the next version whenever it is ready",
    "the revenue charts are much easier to read",
    "send it to the wider team",
    "add a short note explaining why",
    "Thanks for sending over the draft",
    "I went through it this morning",
    "I think it is in really good shape overall",
    # mixed register (optional bilingual habit)
    "please find attached the quarterly report draft",
    "happy to review the updated version",
]

CORPORA = {
    "default": DEFAULT,
    "minimal": [
        "Best,\nDaniel",
        "Thanks again for putting this together.\n\nBest,\nDaniel",
        "the marketing spend went up in March",
    ],
}
