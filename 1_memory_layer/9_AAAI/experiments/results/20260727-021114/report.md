# Experiment report — 20260727-021114

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-27 02:11:24'}`

Statuses: study1=DONE, study2=SKIPPED, study3=DONE, study4=DONE

```
Study 1: availability small ON 6/7 OFF 0/7; large ON 24/25 OFF 0/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1); extraction noise 0/16, seeds 30/31; latency @270 p50=0.014ms p95=0.0478ms; @19895 p50=10.9555ms p95=12.8005ms; budget_ok=True
  [7.9s]
```

```
Study 2: SKIPPED (no in-app log; protocol-only, as stated in the paper)
  [0.0s]
```

```
Study 3 (acceptance_true / injected chars, mean over seeds):
  mixed/associative/b240 A 0.705/201c  B 0.686/199c  C 0.680/169c
  mixed/associative/b800 A 0.698/297c  B 0.691/297c  C 0.691/297c
  mixed/balanced/b240    A 0.794/202c  B 0.774/201c  C 0.764/168c
  mixed/balanced/b800    A 0.792/290c  B 0.773/290c  C 0.773/290c
  mixed/repetition/b240  A 0.764/202c  B 0.735/200c  C 0.707/167c
  mixed/repetition/b800  A 0.775/293c  B 0.767/292c  C 0.767/292c
  mnl/associative/b240   A 0.738/200c  B 0.725/198c  C 0.720/166c
  mnl/associative/b800   A 0.746/302c  B 0.737/302c  C 0.737/302c
  mnl/balanced/b240      A 0.852/201c  B 0.836/200c  C 0.834/166c
  mnl/balanced/b800      A 0.862/292c  B 0.857/293c  C 0.857/293c
  mnl/repetition/b240    A 0.823/200c  B 0.802/197c  C 0.774/166c
  mnl/repetition/b800    A 0.831/296c  B 0.828/296c  C 0.828/296c
  nested/associative/b240 A 0.730/200c  B 0.724/198c  C 0.717/166c
  nested/associative/b800 A 0.747/290c  B 0.743/290c  C 0.743/290c
  nested/balanced/b240   A 0.854/201c  B 0.841/200c  C 0.833/166c
  nested/balanced/b800   A 0.856/291c  B 0.852/292c  C 0.852/292c
  nested/repetition/b240 A 0.817/201c  B 0.790/199c  C 0.771/167c
  nested/repetition/b800 A 0.825/297c  B 0.819/296c  C 0.819/296c
  gain retention under mismatch: mixed/associative/b240=1.354, mixed/associative/b800=0.795, mixed/balanced/b240=1.59, mixed/balanced/b800=3.958, mixed/repetition/b240=1.182, mixed/repetition/b800=2.333, nested/associative/b240=0.735, nested/associative/b800=0.409, nested/balanced/b240=1.126, nested/balanced/b800=0.854, nested/repetition/b240=0.963, nested/repetition/b800=1.694
  [2.4s]
```

```
Study 4 (availability on the large harness; deadline 20ms):
  pfm_full         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.045ms, violations=0, identity 8/8, stale_coinject=True
  no_participants  24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0368ms, violations=0, identity 5/8, stale_coinject=True
  no_graph         24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.0461ms, violations=0, identity 8/8, stale_coinject=True
  no_recency       24/25 (associative 2/2, cjk 1/1, conflict 1/1, direct 20/20, known-limit 0/1), p95=0.042ms, violations=0, identity 8/8, stale_coinject=True
  recency_only     1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  random_k         1/25 (associative 0/2, cjk 0/1, conflict 0/1, direct 1/20, known-limit 0/1)
  mem0             SKIPPED
  langmem          SKIPPED
  [0.2s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
