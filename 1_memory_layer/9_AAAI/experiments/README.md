# experiments/ — aaai2027_full.tex 的 Studies 1–4 实现

所有参数集中在 [config.yaml](config.yaml)（DPFM 系统参数镜像
`../../8_dpfm_application/docs/dpfm-parameter-design.csv`）。底层复用
`../../5_dpfm/dpfm.py` 参考实现；语料/场景从 Swift harness 1:1 移植
（[corpus.py](corpus.py)）。

## 运行

```bash
cd 9_AAAI/experiments
python3 run_all.py --smoke      # ~30s 冒烟测试
python3 run_all.py              # 完整运行（数分钟）
python3 run_all.py --only study3
```

结果写入 `results/<timestamp>/`：每个 study 一个 JSON + `config_used.yaml`
+ `report.md` 汇总。

## Study 与论文章节的对应

| 模块 | 论文位置 | 状态 |
|---|---|---|
| `study1_replay.py` | Experiments → Study 1（Tables 2–4） | 完整复现（小/大 replay + 抽取质量 + 20k 延迟基准）。注意：论文表格里的延迟是 **Swift release build** 数字；本处 Python 数字用于协议复现，不替换论文数字 |
| `study2_inapp.py` | Study 2 | 需要部署 app 导出的 JSONL 日志（`study2.log_path`）；无日志时 SKIPPED——该实验无法离线模拟，论文对应部分保持 protocol-only 措辞 |
| `study3_choice.py` | Choice-Theoretic Serving + Study 3 | 三臂仿真（A 常数 top-k / B 在线 MLE top-k / C MLE+DP 选品）+ mixed/nested logit 模型失配鲁棒性（gain retention）。特征冻结（无闭环 heat 动态），synthetic usage history 提供 heat 方差 |
| `study4_baselines.py` | Study 4 | 消融基线各对应一类失败模式（no_participants→misattributed、no_recency→stale、no_graph→associative）；mem0/langmem 未安装则 SKIPPED 并记录原因 |

## 把结果写回论文时

1. Study 3/4 的数字填进 tex 里对应的 `\todo{...}`；
2. Study 3 的 `theta_hat` vs `theta_star`（参数恢复）支撑"个体画像可解释"的主张；
3. Study 4 的 per-category 退化（associative/conflict 列）是 gap 论证的实测版；
4. 任何 SKIPPED 的实验，论文中相应承诺必须保持 "propose/protocol" 措辞。
