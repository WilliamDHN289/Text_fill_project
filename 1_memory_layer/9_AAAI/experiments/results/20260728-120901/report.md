# Experiment report — 20260728-120901

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 12:09:46'}`

Statuses: study6=DONE

```
Study 6 (baselines, corpus=noisy, 240 queries, 1160 valid facts):
  pfm_full       clean 0.875 (cur 1.000 stale 0.000 wrong 0.125) lat p50=0.0594ms p95=0.0878ms
  temporal_bm25  clean 0.758 (cur 0.892 stale 0.000 wrong 0.133) lat p50=0.015ms p95=0.0272ms
  bm25_recency   clean 0.212 (cur 0.863 stale 0.633 wrong 0.117) lat p50=0.0355ms p95=0.0827ms
  bm25_plain     clean 0.188 (cur 0.858 stale 0.692 wrong 0.092) lat p50=0.0273ms p95=0.0623ms
  dense          clean 0.196 (cur 0.975 stale 0.779 wrong 0.138) lat p50=15.3557ms p95=37.0915ms
  hybrid_rrf     clean 0.192 (cur 0.879 stale 0.771 wrong 0.113) lat p50=14.7885ms p95=30.1258ms
  pfm_snapshot   clean 0.875 (cur 1.000 stale 0.000 wrong 0.125) lat p50=0.0ms p95=0.0ms
  success@D: pfm_full=0.88@0.5ms→0.88@20ms; temporal_bm25=0.76@0.5ms→0.76@20ms; bm25_recency=0.21@0.5ms→0.21@20ms; bm25_plain=0.19@0.5ms→0.19@20ms; dense=0.00@0.5ms→0.15@20ms; hybrid_rrf=0.00@0.5ms→0.17@20ms; pfm_snapshot=0.88@0.5ms→0.88@20ms
  [45.3s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
