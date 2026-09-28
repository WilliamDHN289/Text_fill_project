# Experiment report — 20260728-115357-smoke

`{'python': '3.11.1', 'platform': 'macOS-26.5-arm64-arm-64bit', 'machine': 'arm64', 'timestamp': '2026-07-28 11:53:57'}`

Statuses: study7=ERROR

```
study7: ERROR
Traceback (most recent call last):
  File "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/experiments/run_all.py", line 89, in main
    result = mod.run(cfg, out_dir)
             ^^^^^^^^^^^^^^^^^^^^^
  File "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/experiments/study7_llm.py", line 153, in run
    arms, _ = R.build_arms(retr_names, mem, cfg)
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/experiments/retrievers.py", line 261, in build_arms
    arm = ARM_CLASSES[n]()
          ~~~~~~~~~~~^^^
KeyError: False

  [0.1s]
```

Paper cross-check: Study-1 availability/extraction must match aaai2027_full.tex Tables 2-4 (Swift reference numbers in study1.json expected_from_paper); Study-3 feeds the Choice-Theoretic Serving section; Study-4 feeds the baselines subsection. Latency absolute values are Python-implementation numbers — the paper's Swift release-build numbers remain the deployment claim.
