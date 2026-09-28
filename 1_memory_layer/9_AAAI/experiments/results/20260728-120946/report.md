# Experiment report — 20260728-120946

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 12:16:25'}`

Statuses: study7=DONE

```
Study 7 (frozen LLM = qwen2:7b, 120 queries):
  off          correct 0.000 stale 0.000 wrong-person 0.000 other 1.000 TTFT p50=296.1ms
  pfm_full     correct 0.925 stale 0.000 wrong-person 0.000 other 0.075 TTFT p50=1193.5ms
  bm25_plain   correct 0.517 stale 0.358 wrong-person 0.008 other 0.117 TTFT p50=1036.1ms
  [398.3s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
