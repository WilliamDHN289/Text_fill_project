# Experiment report — 20260728-115304-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 11:53:05'}`

Statuses: study5=DONE

```
Study 5 (temporal): 45 labeled queries/corpus, 30 chains
  lean   keyed/b240     current 1.000 stale 0.000 coinject 0.000 wrong 0.289 clean 0.711
  lean   keyed/b800     current 1.000 stale 0.000 coinject 0.000 wrong 0.289 clean 0.711
  lean   keyless/b240   current 0.889 stale 0.756 coinject 0.644 wrong 0.133 clean 0.178
  lean   keyless/b800   current 0.889 stale 0.756 coinject 0.644 wrong 0.244 clean 0.178
  noisy  keyed/b240     current 1.000 stale 0.000 coinject 0.000 wrong 0.289 clean 0.711
  noisy  keyed/b800     current 1.000 stale 0.000 coinject 0.000 wrong 0.289 clean 0.711
  noisy  keyless/b240   current 0.889 stale 0.756 coinject 0.644 wrong 0.133 clean 0.178
  noisy  keyless/b800   current 0.889 stale 0.756 coinject 0.644 wrong 0.244 clean 0.178
  [0.3s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
