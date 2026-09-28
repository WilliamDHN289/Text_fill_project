# 9_AAAI — DPFM 的学术化投稿包

把 `5_dpfm`（Dual-Path Fact Memory，已在 `8_dpfm_application` 里跑通并有真实
延迟/命中率数据）包装为面向 AAAI 的学术贡献：定位一个真实存在的文献 gap，
把工程系统重述为一个有理论根基、可复现评估的研究框架，并产出可直接投递的
英文 abstract。

## ⚠️ 时间线先读（2026-07-20 检索确认）

| 事项 | 日期 | 来源 |
|---|---|---|
| **AAAI-27 主赛道 abstract 截止** | **2026-07-21 23:59 UTC-12**（即**明天**） | aaai.org/conference/aaai/aaai-27/submission-instructions |
| AAAI-27 主赛道全文截止 | 2026-07-28 23:59 UTC-12 | 同上 |
| 正文页数上限 | 9 页（第 8–9 页仅限参考文献，正文≤7页） | 同上 |
| IAAI-27（部署型应用track）终稿 | "不早于 7 月 27 日"，具体日期待官网公布 | aaai.org/conference/aaai/aaai-27/iaai-27-call |

**这意味着**：如果目标是 AAAI-27 主赛道，摘要注册这一步幾乎没有缓冲时间了——
今天/明天就要把 [3_abstract_AAAI.md](3_abstract_AAAI.md) 里的内容提交到
OpenReview 占位。全文 7 页正文在 8 天内从零写完 + 补实验，压力很大，建议
现实评估：

1. **摘要先占位**：先用本文件夹的 abstract 完成 7/21 的注册（内容已可用），
   全文截止日(7/28) 前再决定是否真的提交完整 PDF——AAAI 允许注册摘要后
   不交全文（只是浪费一次占位，无处罚）。
2. **主赛道 vs IAAI 的取舍**：DPFM 已经是**跑在真实产品 FlowIn 里**的系统，
   这更贴近 **IAAI（Innovative Applications of AI）** 的定位——它明确说
   "purely theoretical work and algorithmic descriptions are more suited for
   AAAI-27〔主赛道〕"，而 IAAI 要的正是"部署+真实数据"。IAAI 终稿截止更晚
   （不早于 7/27，具体日期未公布），时间上更从容。若要投主赛道，需要把
   [2_framework_design.md](2_framework_design.md) §4 提出的"选择模型 +
   选品优化"（把 prompt 注入建模为带预算约束的 assortment optimization）
   这类**新算法贡献**做实，否则容易被认为"工程系统重写成论文"而非"新研究"。
3. 若时间实在不够，**目标改为 AAAI-28 或相关 workshop/demo track** 也是合理
   选项——本文件夹的文献综述和框架设计对任一目标都可直接复用。

## 文件索引

| 文件 | 内容 |
|---|---|
| [1_gap_analysis.md](1_gap_analysis.md) | 文献综述 + gap 论证：本地已收录的 6 篇系统论文 + 新检索的 2026 年综述/新系统，逐一对照用户提出的 3 个特质，证明"个体特异性 + 端侧延迟/存储约束 + 生物启发式短长期记忆"这一组合尚无人覆盖 |
| [2_framework_design.md](2_framework_design.md) | 学术化框架设计：Personal Fact Memory (PFM) 范式，三大支柱的形式化定义、与现有 DPFM 实现的映射表（已实现 vs. 待补的新贡献）、评估计划、局限性 |
| [3_abstract_AAAI.md](3_abstract_AAAI.md) | 可直接投递的英文 abstract（含 title/keywords/subject area 建议）+ 中文对照 |
| [references.bib](references.bib) | 上述两份文档中引用文献的 BibTeX（新 2026 预印本的作者/日期已逐篇核对 arXiv 页面；投稿前仍建议再核一遍，预印本可能会改版本号） |

## 与代码的关系

本文件夹**不改动**任何已有代码（`5_dpfm/dpfm.py`、`8_dpfm_application/`）。
[2_framework_design.md](2_framework_design.md) 里标注为"待补"的部分
（主要是自适应融合权重学习）是论文如果要投主赛道、最需要在 7/28 前
真正跑出实验结果的部分——其余章节都可以直接引用已有的
`DPFM-EXPERIMENT-REPORT.md` 数据，不需要重新实验。
