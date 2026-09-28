# AAAI 投稿 Abstract（可直接使用）

## Title

**Personal Fact Memory: A Cognitively-Grounded, Latency-Bounded Memory Layer
for On-Device LLM Assistants**

*(备选副标题，若投 IAAI 部署型 track，建议换成更强调落地的版本：*
*"DPFM: A Deployed, Cognitively-Grounded Fact Memory for a Production
On-Device Autocomplete Assistant")*

## Abstract（英文，投稿正文用，约 275 词；v3 合并版）

*（v3 说明：以"三约束联合 + deadline-constrained 形式化 + 失败类型学"的
新框定为骨架，保留生物学遗忘机制与 OR/选择模型贡献，只保留已实测的数字，
删去尚无结果的评估承诺——摘要注册后不可实质改动，故承诺范围以 7/28 前
可交付为准。）*

Persistent memory for an on-device language assistant must satisfy three
constraints jointly: retrieved facts must concern the intended person, remain
valid as personal information changes, and arrive before generation commits
to a response. We formulate this as deadline-constrained personal fact
retrieval: returning a small set of currently valid, identity-correct facts
from an evolving personal store within a fixed serving deadline and memory
budget. Existing agent-memory systems address temporal consistency,
personalization, and retrieval efficiency separately, and assume server-scale
infrastructure an on-device assistant cannot afford. We
introduce Personal Fact Memory (PFM), which represents atomic facts in a
bitemporal entity graph where superseding values close their predecessors
instead of competing with them, and retrieves by bounded in-memory lexical
search with local graph expansion; no embedding model or LLM is invoked on
the hot path, and speculative prefetch with deadline racing makes retrieval
non-blocking by construction. Forgetting is biologically grounded: a dual
recency/usage-reinforcement decay -- echoing the Ebbinghaus curve and the
testing effect -- lets facts fade unless reinforced by accepted completions,
stratifies episodic, semantic, and pinned profile memory, and bounds the
store by use rather than corpus size. We further propose a choice-theoretic
serving layer: completion acceptance as discrete user choice, per-user fusion
weights estimated online from implicit accept/reject feedback, and
prompt-slot allocation under a character budget as constrained assortment
optimization. In offline replay from a deployed autocomplete assistant, PFM
raises ground-truth fact availability from 0% to 96% (24/25 scenarios) and
sustains 1.8 ms median retrieval at 20,000 facts -- two orders of magnitude
below LLM prefill. PFM treats stale, misattributed, and late facts as
distinct failures, and the individual, not the corpus, as the unit of
design.

## Keywords

Personalized Memory Systems; On-Device LLM Agents; Cognitively-Inspired
Memory Architecture; Low-Latency Retrieval-Augmented Generation; Bi-Temporal
Knowledge Representation; Discrete Choice Models; Assortment Optimization;
Real-Time Text Completion

## 建议的 Subject Area（OpenReview 表单填写参考）

- **首选**：Natural Language Processing → Applications / Dialogue and
  Interactive Systems
- **次选**：Humans and AI → Human-AI Collaboration
- **次选**：Multiagent Systems → Agent Architectures and Frameworks

（三个都贴合：这是一篇"NLP 应用 + 人机协作 + agent 架构"三重交叉的论文，
具体选哪个当 primary 取决于最终写作时把哪部分论证得最扎实——如果 §4 的
选择模型 + 选品优化做出来了，"Multiagent Systems / Agent Architectures"
更合适做首选，因为那部分是算法贡献；如果时间不够只交 P1/P2/P3 + 实测
数据，"NLP Applications" 更稳妥。）

## 中文对照（内部使用，非投稿材料）

面向端侧语言助手的持久记忆必须同时满足三个约束：检索到的事实须关联
正确的当事人、须在个人信息不断变化中保持当前有效、且须在生成过程落笔
之前到达。我们将其形式化为**截止时间约束下的个人事实检索**——在固定的
服务截止时间与有界内存占用内，从不断演化的个人存储中返回一小组当前
有效、身份正确的事实——并指出现有 agent 记忆系统将时序一致性、个性化
与检索效率分开处理，且建立在端侧助手无法负担的服务端级基础设施之上。
我们提出 Personal Fact Memory（PFM）：原子事实存于双时态实体图中，
取代旧值的新值会"关闭"其前身，而非与之并存竞争；检索为有界的内存词法
搜索加局部图扩展，热路径不调用任何 embedding 模型或 LLM，推测预取与
截止时间竞速使检索在构造上即为非阻塞。遗忘机制有生物学根基：呼应
Ebbinghaus 遗忘曲线与测试效应的 recency/使用强化双衰减，让未被采纳
补全强化的事实自然消退，将情景、语义与固定画像记忆分层，并使存储规模
由使用模式而非语料量决定。我们进一步提出选择理论化的服务层：补全的
接受即用户的离散选择，按用户从隐式接受/拒绝反馈在线估计融合权重，
字符预算下的 prompt 槽位分配即带约束的选品优化（assortment
optimization）。在已部署自动补全助手的离线回放中，PFM 将真值事实
可用率从 0% 提升至 96%（24/25 场景），并在 20,000 条事实规模下保持
1.8 毫秒中位检索延迟——比 LLM prefill 低两个数量级。PFM 将过时、
错误归属与迟到的事实视为三类不同的失败，并把个体——而非语料——作为
设计的单位。

## 提交前检查清单

- [ ] 确认目标 track（主赛道 vs. IAAI，见 [README.md](README.md) 的取舍分析）
- [ ] 若投主赛道：决定是否要在 7/28 前把 [2_framework_design.md](2_framework_design.md)
      §4 的选择模型 + 选品优化三臂消融（§4.4）跑出实验结果；若跑不完，
      摘要最后一句保持 "We further propose..." 的 propose 措辞不变
      （诚实标注为未来工作），不要在正文改成既成结果
- [ ] 若 §4 成为头牌贡献：正文贡献排序应为 assortment 决策框架第一、
      在线选择模型估计第二（学习侧的统计机制已有 RCPO 等先例，单独不够
      新颖）；并把 §4.3 的两段因果链近似作为显式假设段落写进正文
- [ ] 摘要里的数字（96%、24/25、p50 数值）与
      `../8_dpfm_application/docs/DPFM-EXPERIMENT-REPORT.md` 逐一核对一致
- [ ] 全文 PDF 用 AAAI 官方 two-column camera-ready 模板，正文 ≤7 页 + 参考文献 ≤2 页
- [ ] 作者信息、机构、致谢按 AAAI 匿名评审要求处理（如走双盲评审需脱敏）
- [ ] `references.bib` 里 2026 年新预印本的版本号临投稿前再核一次
      （arXiv 预印本可能改版）
