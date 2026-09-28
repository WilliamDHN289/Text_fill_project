# Experiment report — 20260727-021046-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-27 02:10:47'}`

Statuses: study1=DONE, study2=SKIPPED, study3=DONE, study4=DONE

```
Study 1: availability small ON 6/7 OFF 0/7; large ON 24/25 OFF 0/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1); extraction noise 0/16, seeds 30/31; latency @270 p50=0.0145ms p95=0.045ms; @1997 p50=1.0357ms p95=1.3541ms; budget_ok=True
  [0.2s]
```

```
Study 2: SKIPPED (no in-app log; protocol-only, as stated in the paper)
  [0.0s]
```

```
Study 3 (acceptance_true / injected chars, mean over seeds):
  mnl/associative/b240   A 0.749/210c  B 0.707/208c  C 0.697/172c
  mnl/associative/b800   A 0.781/296c  B 0.742/296c  C 0.742/296c
  mnl/balanced/b240      A 0.858/198c  B 0.840/197c  C 0.844/164c
  mnl/balanced/b800      A 0.859/275c  B 0.844/276c  C 0.844/276c
  mnl/repetition/b240    A 0.856/200c  B 0.773/197c  C 0.839/169c
  mnl/repetition/b800    A 0.811/288c  B 0.796/286c  C 0.796/286c
  [0.1s]
```

```
Study 4 (availability on the large harness; deadline 20ms):
  pfm_full         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.047ms, violations=0, identity 8/8, stale_coinject=True
  no_participants  24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0395ms, violations=0, identity 5/8, stale_coinject=True
  no_graph         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0475ms, violations=0, identity 8/8, stale_coinject=True
  no_recency       24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0456ms, violations=0, identity 8/8, stale_coinject=True
  recency_only     1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  random_k         1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  mem0             SKIPPED
  langmem          SKIPPED
  [0.2s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
