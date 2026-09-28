# Experiment report — 20260728-115427-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 11:54:51'}`

Statuses: study7=DONE

```
Study 7 (frozen LLM = qwen2:7b, 4 queries):
  off          correct 0.000 stale 0.000 wrong-person 0.000 other 1.000 TTFT p50=330.0ms
  pfm_full     correct 1.000 stale 0.000 wrong-person 0.000 other 0.000 TTFT p50=1136.5ms
  bm25_plain   correct 0.750 stale 0.250 wrong-person 0.000 other 0.000 TTFT p50=968.1ms
  [23.8s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
