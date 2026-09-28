# Experiment report — 20260727-020353-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-27 02:03:53'}`

Statuses: study1=DONE, study2=SKIPPED, study3=DONE, study4=DONE

```
Study 1: availability small ON 6/7 OFF 0/7; large ON 24/25 OFF 0/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1); extraction noise 0/16, seeds 30/31; latency @270 p50=0.014ms p95=0.044ms; @1997 p50=1.0136ms p95=1.1379ms; budget_ok=True
  [0.1s]
```

```
Study 2: SKIPPED (no in-app log; protocol-only, as stated in the paper)
  [0.0s]
```

```
Study 3 (acceptance_true / injected chars, mean over seeds):
  mnl/associative        A 0.992/288c  B 0.992/289c  C 0.992/289c
  mnl/balanced           A 0.997/300c  B 0.997/302c  C 0.997/302c
  mnl/repetition         A 0.996/296c  B 0.996/298c  C 0.996/298c
  [0.0s]
```

```
Study 4 (availability on the large harness; deadline 20ms):
  pfm_full         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0447ms, violations=0
  no_participants  24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0402ms, violations=0
  no_graph         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.045ms, violations=0
  no_recency       24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0422ms, violations=0
  recency_only     1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  random_k         1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  mem0             SKIPPED
  langmem          SKIPPED
  [0.1s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
