# Experiment report — 20260728-120852

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 12:09:00'}`

Statuses: study5=DONE

```
Study 5 (temporal): 240 labeled queries/corpus, 160 chains
  lean   keyed/b240     current 0.887 stale 0.000 coinject 0.000 wrong 0.000 clean 0.887
  lean   keyed/b800     current 1.000 stale 0.000 coinject 0.000 wrong 0.117 clean 0.883
  lean   keyless/b240   current 0.675 stale 0.408 coinject 0.267 wrong 0.000 clean 0.408
  lean   keyless/b800   current 0.812 stale 0.654 coinject 0.517 wrong 0.004 clean 0.292
  noisy  keyed/b240     current 0.896 stale 0.000 coinject 0.000 wrong 0.000 clean 0.896
  noisy  keyed/b800     current 1.000 stale 0.000 coinject 0.000 wrong 0.125 clean 0.875
  noisy  keyless/b240   current 0.667 stale 0.388 coinject 0.250 wrong 0.000 clean 0.417
  noisy  keyless/b800   current 0.812 stale 0.662 coinject 0.525 wrong 0.004 clean 0.283
  [8.6s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
