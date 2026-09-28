"""Representative passages for the autocomplete harness.

We want prefixes that look like real production typing, not toy one-word inputs.
Two registers are included: a work email and a piece of prose. The email is the
default because Smart-Compose-style autocomplete is most valuable in that setting.
"""

PASSAGES = {
    # A realistic work email. This is the default test passage.
    "email": (
        "Hi Sarah,\n\n"
        "Thanks for sending over the draft of the quarterly report yesterday. "
        "I went through it this morning and I think it is in really good shape "
        "overall. The summary on the first page is clear and the revenue charts "
        "are much easier to read than last time.\n\n"
        "I do have a couple of small suggestions before we send it to the wider "
        "team. First, it would be helpful to add a short note explaining why the "
        "marketing spend went up in March, since a few people asked about that "
        "last quarter. Second, could you double check the numbers in the table on "
        "page four? One of the totals does not seem to match the chart above it.\n\n"
        "Other than that, I think we are ready to go. Let me know if you want to "
        "hop on a quick call to walk through the changes, otherwise I am happy to "
        "review the next version whenever it is ready.\n\n"
        "Thanks again for putting this together.\n\n"
        "Best,\n"
        "Daniel"
    ),

    # A paragraph of prose / general knowledge writing.
    "prose": (
        "The history of the printing press is often told as a single moment of "
        "invention, but the reality was far more gradual. Long before Gutenberg "
        "assembled his famous press in the middle of the fifteenth century, "
        "printers in East Asia had been using carved wooden blocks to reproduce "
        "text and images for centuries. What changed in Europe was not the idea "
        "of printing itself, but the combination of movable metal type, an oil "
        "based ink that would stick to that type, and a press adapted from the "
        "machines already used to crush grapes and olives. Together these "
        "innovations made it possible to produce books quickly and cheaply, and "
        "within a few decades the number of books in circulation had grown "
        "dramatically across the continent."
    ),
}

DEFAULT = "email"
