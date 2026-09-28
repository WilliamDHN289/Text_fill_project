# Experiment report — 20260728-114745-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 11:47:45'}`

Statuses: study5=DONE

```
Study 5 (temporal): 45 labeled queries/corpus, 30 chains
  lean   keyed/b240     current 0.844 stale 0.000 coinject 0.000 wrong 0.022 clean 0.822
  lean   keyed/b800     current 0.844 stale 0.000 coinject 0.000 wrong 0.044 clean 0.800
  lean   keyless/b240   current 0.778 stale 0.644 coinject 0.489 wrong 0.000 clean 0.289
  lean   keyless/b800   current 0.844 stale 0.733 coinject 0.600 wrong 0.044 clean 0.244
  noisy  keyed/b240     current 0.844 stale 0.000 coinject 0.000 wrong 0.022 clean 0.822
  noisy  keyed/b800     current 0.844 stale 0.000 coinject 0.000 wrong 0.044 clean 0.800
  noisy  keyless/b240   current 0.800 stale 0.622 coinject 0.489 wrong 0.000 clean 0.311
  noisy  keyless/b800   current 0.844 stale 0.733 coinject 0.600 wrong 0.044 clean 0.244
  [0.1s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
