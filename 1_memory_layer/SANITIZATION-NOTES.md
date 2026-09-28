# Exhibit A compliance mapping — paper-v5 → paper-v6

Source of the boundary: *Exhibit A, Confidential Information in AAAI 2027 Submission*, AstraBreeze Inc., 31 July 2026.
Files: `paper-v6-main.tex`, `paper-v6-supplement.tex` (new). `paper-v5-*.tex` left untouched as the original record.

Exhibit A ¶(a) demands withdrawal of the v5 submission and states it cannot be cured by redaction. v6 is **not** a redacted v5; it is a new manuscript built to the ¶(b) carve-out: Part IV elements only, synthetic data only, no description, screenshot, measurement, or data of Company systems. Withdrawal of v5 remains a separate obligation this rewrite does not discharge.

## Part I — deployed product internals: all removed

| Item | v5 location | Action in v6 |
|---|---|---|
| I-1 send-confirmation capture | Deployment Setting | Section deleted in full |
| I-2 context-transition capture, async handoff | Deployment Setting | Deleted |
| I-3 snapshot prompt-prefix stability, prompt caching, cap "cannot crowd out live context" | Deployment Setting | Deleted; `[Relevant memory]` block name and placement dropped. Only the abstract budget *B* of Definition 1 survives |
| I-4 Figure 1 product screenshot + interaction model | Fig. 1, Introduction | Figure, `figures/teaser.pdf`, and the greyed-continuation / accept / dismiss description deleted |
| I-5 acceptance tracking driving retention and ranking | Memory Construction | Acceptance semantics deleted; usage score redefined as a decaying counter over prior *serving* |
| I-6 replay through Company capture and serving code; deployed-store latency | Replay Setup, Target Fact Availability, Identity Attribution, Latency and scaling, supplement §C.3 | **All replay experiments deleted**: 6/7 and 24/25 availability, 0/7 and 0/25 no-memory, 30-of-31 extraction, 8/8 vs 5/8 identity probes, ablation table, 28-day corpus, 287 messages / 270 facts, 0.011 ms and 1.81 ms deployed-store latencies |

## Part II — private-branch functionality: all removed

| Item | Action in v6 |
|---|---|
| II-1 privacy gates (password fields, credential managers, key/token heuristic) | Sentence deleted entirely; no substitute |
| II-2 background extraction pipeline | Pipeline vocabulary deleted. What remains is the construction/serving separation *as an assumption of Proposition 2*, which Exhibit A IV-5 does not claim — see ambiguity A2 |
| II-3 on-device local fact store | Deleted. v6 describes only a single-process in-memory reference implementation used for measurement |
| II-4 window title as interlocutor identifier | Deleted. Participant metadata is now stated as supplied with each record by the corpus generator |
| II-5 add/update/confirm/drop semantics, last-confirmed tracking | Operation vocabulary and "re-observation reinforces the value" phrasing dropped. The keyed-supersession formalism and Proposition 1 are retained under IV-2 |

## Part III — concepts: removed or re-anchored to public literature

| Item | Action in v6 |
|---|---|
| III-1 on-device single-user framing vs. cloud memory | Title changed to *Interactive Latency Budgets*; "on-device", "macOS", "commercially deployed" removed throughout. Motivation now cites published constrained-memory work (AME, EMG-RAG, Lightweight LLM Agent Memory) |
| III-2 no model on the retrieval path | Retained but re-grounded: presented as a measured result of our own baseline study (MiniLM query encoding 15.4 ms vs. deadline) and of the IV-5 protocol, not as a design premise. See ambiguity A1 |
| III-3 lexical BM25-family retrieval; CJK attention | BM25F retained under IV-3 (scoring formula and parameterization). **All CJK material deleted** (the CJK scenario lived in the replay harness, which is gone) |
| III-4 episodic/semantic/profile classes, pinned profile core | Paragraph deleted. Pruning statement kept in generic recency+usage form with no fact-class taxonomy and no pinning |
| III-5 bounded memory block, B-character budget | Product-facing description deleted. *B* survives only as the abstract prompt-capacity constraint of Definitions 1–2 (IV-1) and as a benchmark axis (IV-6). See ambiguity A3 |

## Part IV — retained

Retained in full: problem definition and taxonomy (Definitions 1–2); keyed-supersession formalism, Propositions 1–2 and proofs; retrieval parameterization and scoring formula; entity co-occurrence graph; snapshot/fresh serving protocol and latency bounds; the 240-query update benchmark; retrieval-baseline comparison and frozen-model replay, both on synthetic corpora. Budget-aware selection (Proposition 3) and its synthetic-response simulation are retained: they appear nowhere in Parts I–III and use simulated data only.

## Ambiguities requiring the Company's written confirmation (Exhibit A, closing paragraph)

- **A1 — III-2 vs. IV-5.** IV-5 disclaims the serving-protocol formalization *and its latency bounds*; those bounds exist only because no model runs on the retrieval path. III-2 claims that decision as a concept. v6 keeps the property and sources it to our own measurements. Confirm.
- **A2 — II-2 vs. IV-5.** Proposition 2 states that the waiting bound is independent of extraction and index maintenance, which presupposes construction off the request path. II-2 claims that separation. Confirm.
- **A3 — III-5 vs. IV-1/IV-3.** IV-1 disclaims Definitions 1–2, which contain *B*; IV-3 disclaims term caps; IV-6 disclaims a benchmark evaluated "at two prompt budgets". III-5 claims the B-character budget. v6 keeps *B* only in those three permitted roles. Confirm.
- **A4 — III-3 vs. IV-3.** IV-3 disclaims the scoring formula and field weights, which are BM25F. III-3 claims the choice of BM25-family retrieval. Confirm.
- **A5 — III-1 scope.** Whether "single-user personal memory under a latency budget" can be discussed at all when sourced to published third-party work. v6 avoids "on-device" entirely as a precaution.

## Evidence lost, and what must be re-run to restore it

1. **Participant-attribution ablation.** The 8/8 vs. 5/8 identity result was deployed-replay and is gone. v6's identity claim now rests indirectly on the .892 → 1.000 current-value-recall gap between BM25+validity and PFM in Table 2. To restore direct evidence, re-run a participant-field ablation on the synthetic 240-query benchmark, which already contains six shared-first-name pairs. No such numbers were invented.
2. **Sparse-vs-dense latency contrast.** The claim "latency is a property of term-frequency structure, not fact count" previously leaned on the deployed 1.81 ms @ 20k figure. v6 substitutes a within-synthetic comparison (0.06 ms on the 1,160-fact benchmark corpus vs. 0.71 ms at 1,000 dense facts). A synthetic sparse-distribution scaling run would make this argument properly.
3. **Contribution 3** is now "Controlled empirical study", not "System evidence". Reviewers will read this as a weaker systems paper; the honest framing is in Limitations.

## Not covered by this pass

`10_AAAI_code/`, `9_AAAI/figures/teaser.*`, `make_teaser*.py`, and any artifact or code release. Exhibit A I-6 states the experiments were executed through the Company's capture and serving code; the code drop and the teaser assets need the same review before any release or supplementary upload.
