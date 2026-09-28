# Experiment report — 20260728-115322-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 11:53:38'}`

Statuses: study6=DONE

```
Study 6 (baselines, corpus=noisy, 45 queries, 180 valid facts):
  pfm_full       clean 0.711 (cur 1.000 stale 0.000 wrong 0.289) lat p50=0.0238ms p95=0.036ms
  temporal_bm25  clean 0.711 (cur 1.000 stale 0.000 wrong 0.289) lat p50=0.0066ms p95=0.013ms
  bm25_recency   clean 0.200 (cur 0.956 stale 0.711 wrong 0.244) lat p50=0.0115ms p95=0.0206ms
  bm25_plain     clean 0.178 (cur 0.956 stale 0.733 wrong 0.222) lat p50=0.0101ms p95=0.0166ms
  dense          clean 0.178 (cur 1.000 stale 0.756 wrong 0.267) lat p50=7.6544ms p95=8.1342ms
  hybrid_rrf     clean 0.178 (cur 1.000 stale 0.733 wrong 0.289) lat p50=7.6493ms p95=8.1192ms
  pfm_snapshot   clean 0.711 (cur 1.000 stale 0.000 wrong 0.289) lat p50=0.0ms p95=0.0ms
  success@D: pfm_full=0.71@0.5ms→0.71@20ms; temporal_bm25=0.71@0.5ms→0.71@20ms; bm25_recency=0.20@0.5ms→0.20@20ms; bm25_plain=0.18@0.5ms→0.18@20ms; dense=0.00@0.5ms→0.18@20ms; hybrid_rrf=0.00@0.5ms→0.18@20ms; pfm_snapshot=0.71@0.5ms→0.71@20ms
  [15.2s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
