# Example suggestions (real harness output)

Model: **gemma-4-E2B base**, Q4_K_M, Metal, greedy (temp=0), n_predict=24.
Passage: work email. `shown` = what an inline UI would display (trimmed to first clause/sentence).

Aggregate over the 21-request loop: word-prefix-match mean **0.67**, histogram {'0': 12, '2': 3, '1': 5, '3': 1} (matched leading words vs the author's actual continuation — a strict lower bound).

| # | text typed so far (tail) | suggestion shown | author actually wrote next |
|---|---|---|---|
| 0 | …ah,\n\nThanks for sending over the | **details.** |  draft of the quarterly report yesterday. I we |
| 1 | …quarterly report yesterday. I went | **through it and made some comments.** |  through it this morning and I think it is in  |
| 2 | …ugh it this morning and I think it | **looks great.** |  is in really good shape overall. The summary  |
| 3 | …ly good shape overall. The summary | **is clear and concise, and the data is well-presented.** |  on the first page is clear and the revenue ch |
| 4 | …on the first page is clear and the | **data is presented in a way that is easy to understand.** |  revenue charts are much easier to read than l |
| 5 | …harts are much easier to read than | **the previous version.** |  last time.  I do have a couple of small sugge |
| 6 | …ast time.\n\nI do have a couple of | **comments:** |  small suggestions before we send it to the wi |
| 7 | …ggestions before we send it to the | **board.** |  wider team. First, it would be helpful to add |
| 8 | …eam. First, it would be helpful to | **have a section that summarizes the key points of the report.** |  add a short note explaining why the marketing |
| 9 | … note explaining why the marketing | **and fundraising numbers are down this quarter.** |  spend went up in March, since a few people as |
| 10 | …pend went up in March, since a few | **people have asked about that.** |  people asked about that last quarter. Second, |
| 11 | …t that last quarter. Second, could | **you add a note about the new marketing plan for the next quarter?** |  you double check the numbers in the table on  |
| 12 | …ble check the numbers in the table | **on page 3?** |  on page four? One of the totals does not seem |
| 13 | … page four? One of the totals does | **not seem to be correct.** |  not seem to match the chart above it.  Other  |
| 14 | … seem to match the chart above it. | **∅** |   Other than that, I think we are ready to go. |
| 15 | …er than that, I think we are ready | **to send it to the wider team.** |  to go. Let me know if you want to hop on a qu |
| 16 | …ady to go. Let me know if you want | **to send it to the wider team.** |  to hop on a quick call to walk through the ch |
| 17 | …ant to hop on a quick call to walk | **through the report.** |  through the changes, otherwise I am happy to  |
| 18 | …e changes, otherwise I am happy to | **send it to the wider team.** |  review the next version whenever it is ready. |
| 19 | …next version whenever it is ready. | **∅** |   Thanks again for putting this together.  Bes |
| 20 | …ng this together.\n\nBest,\nDaniel | **∅** |  |

## Mid-cursor (edit-in-the-middle) — the suffix-collision failure (config H)

Model: **gemma-4-E2B base**, Q4_K_M, Metal, greedy, n_predict=24, `--mid-cursor`.
Here the cursor sits *inside* the email (the author went back to insert text), so the
suffix already exists. The model still sees only the prefix — a causal LM cannot
condition on the suffix — and we score the suggestion for **collision** with that
already-written suffix.

Aggregate over the 19 mid-cursor points: **suffix-collision rate 0.47**, mean leading
suffix words duplicated **0.68**, 3-gram verbatim re-use **0.11**. Overlap here is the
*failure* signal (the opposite of the end-of-text table): the model re-proposes text
the author already has just to the right of the cursor.

| # | text before cursor (tail) | suggestion (model, prefix-only) | suffix already to the right | collision |
|---|---|---|---|---|
| 1 | …quarterly report yesterday. I went | **through it and made some comments.** |  through it this morning and I think it is in re | dup 2 words |
| 3 | …good shape overall. The summary | **is clear and concise, and the data is well-presented.** |  on the first page is clear and the revenue char | 3-gram |
| 10 | …spend went up in March, since a few | **people have asked about that.** |  people asked about that last quarter. Second, c | dup 1 word |
| 12 | …double check the numbers in the table | **on page 3?** |  on page four? One of the totals does not seem t | dup 2 words + **contradicts** (3 vs 4) |
| 13 | …page four? One of the totals does | **not seem to be correct.** |  not seem to match the chart above it. | dup 3 words + 3-gram |
| 17 | …want to hop on a quick call to walk | **through the report.** |  through the changes, otherwise I am happy to re | dup 2 words |

Case 12 is the clearest: the model both **duplicates** the suffix ("on page…") and
**contradicts** it ("page 3" vs the author's "page four"), because it has no idea the
"page four" text already exists. A real fill-in-the-middle model would bridge into the
suffix instead of overwriting it. See `WRITEUP.md` Q4.

## Base vs instruction-tuned, identical prefixes (raw, untrimmed)

On gemma-4 the gap is subtler than on older Gemma (no hard markdown leakage), but the **register** still differs: the **base** model continues *as the writer* drafting the email; the **-it** model slips into a *helpful-reviewer* voice ("I've had a chance to review it", "a few minor suggestions"). Base is also in-distribution for raw continuation; -it is used without its chat template, so it can switch to assistant mode or stop early.

| text typed so far (tail) | BASE (raw) | IT (raw) |
|---|---|---|
| …hanks for sending over the |  details.\n\nI have a few questions for you:\n\n1. What is the nam |  project brief. I've had a chance to review it, and I have a f |
| …y report yesterday. I went |  through it and made some comments.\n\nI have a few questions ab |  through it and have some initial thoughts.\n\nOverall, it's a s |
| …his morning and I think it |  looks great. I’m not sure if you’ve seen the new quarterly re | 's a solid start.\n\nI have a few minor suggestions, mainly arou |
| …shape overall. The summary |  is clear and concise, and the data is well-presented.\n\nI have |  is clear and the data presentation is very effective.\n\nI did  |
| …irst page is clear and the |  data is presented in a way that is easy to understand.\n\nI hav |  data presentation is very effective.\n\nI did have a few minor  |
| …e much easier to read than |  the previous version.\n\nI have a few comments and questions th |  the previous version.\n\nI have a few minor suggestions, mainly |
| ….\n\nI do have a couple of |  comments:\n\n1. I think the “What’s Next” section is a bit too  |  minor suggestions, mainly around refining the language in the |
| …s before we send it to the |  board.\n\n1. I think the “What’s Next” section is a bit too lon |  final approvers. Firstly, I think we could strengthen the ana |
| …st, it would be helpful to |  have a section that summarizes the key points of the report.  |  add a brief section on key challenges faced during the quarte |
| …plaining why the marketing |  and fundraising numbers are down this quarter. I think it is  |  spend increased this quarter. Second, and third, could we per |
