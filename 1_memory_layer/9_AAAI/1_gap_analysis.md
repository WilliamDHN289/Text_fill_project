# 文献综述与 Gap 论证

## 0. 检索方法

两条线：

1. **本地已收录**（`../1_literature/`）：Mem0、Zep/Graphiti、HippoRAG、
   MemoryOS、A-MEM、Letta/MemGPT——`5_dpfm/README.md` §2 已把每篇论文
   借鉴的机制映射到 DPFM 的具体模块，这里不重复，只补"这些系统各自的
   假设边界在哪"。
2. **新检索**（2026-07-20，WebSearch + WebFetch 核实到 arXiv 摘要页）：
   聚焦三个方向——(a) LLM agent memory 的最新综述，看社区自己列出的
   open problem 清单里有没有覆盖用户要的三个特质；(b) 端侧/edge LLM
   个人助手的隐私与延迟约束；(c) 认知科学（Ebbinghaus 遗忘曲线、
   互补学习系统理论）启发的记忆架构，看是否已有人把认知科学显式接到
   "个体+端侧"这个场景。结果见下。

## 1. 用户提出的三个特质，逐一对照

### 特质 1 — 个体身份关联（"和本人相关，需清晰关联各场景信息并正确应用"）

| 系统 | 关联机制 | 是否以"单一个体身份"为一等公民 |
|---|---|---|
| Mem0 (arXiv:2504.19413) | 两段式 Extract→Update，事实按语义相似度去重/更新 | 面向多用户 SaaS 记忆服务，"user_id" 是路由维度，不是记忆内部的关联结构 |
| Zep/Graphiti (arXiv:2501.13956) | 知识图谱 + 双时态边 | 图是"世界事实图"，个人身份和其他实体同等对待，无参与者字段的差异化加权 |
| HippoRAG (arXiv:2405.14831) | 实体图 + Personalized PageRank | "Personalized" 指以**查询**为种子做个性化传播，不是以**用户身份**为种子；论文场景是通用多跳 QA，无"谁写给谁"的参与者概念 |
| MemoryOS (arXiv:2506.06326) | heat 驱动分层 | 关注记忆的冷热分层，不显式建模身份/收件人 |
| A-MEM (arXiv:2502.12110) | Zettelkasten 自动链接 | 链接基于内容相似度，非身份实体 |
| Letta/MemGPT (arXiv:2310.08560) | core/archival 分层 | core memory 可存"用户是谁"，但检索侧无参与者字段加权 |
| **Human-Inspired Memory Architecture**（Kerestecioglu et al., Microsoft, arXiv:2605.08538, 2026-05） | 三层（短/中/长期）+ 六种认知机制（consolidation / interference forgetting / engram maturation / reconsolidation / 实体图 / 混合检索） | **论文原文明确不处理**单用户个性化——聚焦跨 session 的 agent 级记忆管理，评测在 VSCode issue tracking（多人协作场景）和 LongMemEval 上，没有"这是我的经理/这是我的项目"这类身份锚定的设计或指标 |

**结论**：现有系统的"关联"要么是语义相似度，要么是通用实体图，**没有一个
把"实体 vs. 参与者(收件人/对话方)"做差异化字段加权，也没有把"矛盾事实必须
以最新版本覆盖而非并存"当作个人场景的核心需求**（Zep 有双时态边，但目的是
知识图谱的时序一致性，不是"我的补全工具需要精确覆写旧账期/旧地址"这种
个人助手的强需求）。DPFM 已经做了这件事（`participants` 字段权重 2.0、
`key` 槽位取代），但目前只是工程选择，论文里需要把它上升为一个显式命题：
**个人记忆的检索单位不是"语义相关的文本"，而是"和查询语境中出现的人/实体
存在归属关系的原子事实"**。

### 特质 2 — 存储与延迟约束（"控制存储空间，确保低延迟"）

| 系统 | 检索路径依赖 | 已发表的延迟数字 | 是否为端侧设计 |
|---|---|---|---|
| Mem0 / Zep / HippoRAG / MemoryOS / A-MEM | 均依赖 embedding 模型 + 向量库（部分+图数据库），Mem0/Zep 还在写路径用 LLM 做抽取/更新决策 | 论文报告的是 QA 任务的**准确率**（LOCOMO、LongMemEval 等基准），几乎不报告端到端加入 embedding/LLM 调用后的**毫秒级延迟**，更不会在"必须与生成过程并行、不可阻塞"这个约束下报告 | 均假设服务端部署，有稳定的 GPU/embedding 服务可用 |
| Human-Inspired Memory Architecture | 显式依赖 `text-embedding-3-large` + GPT-4o | 论文报告的是检索**精度**（97.2% retention precision）和**存储压缩率**（58% store reduction），未见毫秒级延迟数字；作者原文承认"assumes centralized deployment" | 论文正文未讨论端侧/带宽受限场景，未讨论模型量化/裁剪 |
| EdgeTune (ACM/IEEE Embedded AI & Sensing Systems 2026) | 端侧 **参数微调**（LoRA adapter 剪枝布局），不是记忆检索层 | 报告的是微调后模型质量与显存占用 | 是端侧优先设计，但解决的是"让基座模型适应用户"，和"给基座模型一个可查询的外部记忆"是正交问题——不能替代 memory layer |
| "Are We Ready For An Agent-Native Memory System?" (Zhou et al., arXiv:2606.24775, 2026-06) | 系统性质询现有 memory 系统是否"生产就绪"，把延迟预算/存储footprint列为核心待评测维度 | **提出评测框架**（MemoryData 数据集），本身**不提供**一个满足这些约束的系统 | 呼吁而非实现 |

**结论**：延迟/存储约束在综述里被列为开放问题（见下方特质 3 综述表格的
"Memory-efficient architectures"一项），但目前**没有已发表系统在"个人语料
规模（10^3–10^5 条事实）+ 与生成过程并行、不可阻塞"这个具体约束下报告过
毫秒级实测数字**——多数系统的延迟瓶颈（embedding 调用、LLM 抽取/更新决策）
本身就和"端侧、低成本小模型场景"矛盾：如果本地小模型已经是算力紧张的
资源，memory 层再占用一次 embedding/LLM 前向传播是不可接受的开销。DPFM
用纯词法 BM25F + 无 embedding 的实体图给出了一个具体解法，且有实测数据
（20k facts 时 p50=1.8ms，270 facts 时 p50=0.011ms，两者都比 LLM prefill
低 1–2 个数量级）——这是**现有文献里没有对应实测数字的一格**。

### 特质 3 — 短期/长期记忆区分，跨学科（生物学/心理学）启发

| 来源 | 借鉴的认知科学机制 | 是否落到"个体+端侧"场景 |
|---|---|---|
| MemoryBank (arXiv:2305.10250，DPHM 已引用) | Ebbinghaus 遗忘曲线驱动的更新机制 | 面向对话摘要，未讨论端侧延迟 |
| MemoryOS | heat 驱动分层晋升/淘汰，类比操作系统缓存分层而非认知科学 | 未显式对齐心理学机制命名 |
| **Human-Inspired Memory Architecture** | 目前文献中**认知科学对齐程度最高**的系统：互补学习系统理论（海马体快速编码 / 新皮层慢速语义化）、睡眠期巩固（去重合并）、Ebbinghaus 衰减+检索干扰、engram 成熟（记忆形成后有"沉默期"才可检索）、再巩固（提取后进入易变状态可被新信息更新） | 论文原文承认 **engram 成熟与再巩固两个机制"未经实证验证"**——因为 LongMemEval 的问答之间没有重复访问同一记忆的信号，"memories never accumulate repeated access signals"；且该论文自述评测基准与其架构存在"adversarial case"的结构错配 |
| "Ebbinghaus Forgetting Curve and LLM Memory Management" (ICICT 2026) | 首次系统性地把 Ebbinghaus 曲线用于**长上下文管理**（长文档压缩），场景是单次长对话，不是跨天累积的个人语料 | 面向长上下文压缩，非个人记忆层 |
| ZenBrain（arXiv:2604.23878） | 声称集成 15 种认知神经科学模型的"七层"架构 | 尚未见端侧延迟/存储评测，偏概念架构 |

**综述本身怎么看这件事**：`Memory for Autonomous LLM Agents: Mechanisms,
Evaluation, and Emerging Frontiers`（Pengfei Du, arXiv:2603.07670, 2026-03）
给出目前最系统的分类和十条开放问题（§9），其中第 8 条是"Deeper neuroscience
integration"，第 7 条是"Memory-efficient architectures"——**这两条在该综述
里是两条独立的开放问题，作者并未把它们联系到同一个场景下**；综述全文也
**没有把"个性化到单一用户身份"列为一条独立的开放维度**——十条里最接近的是
"Trustworthy reflection"（防止自我强化的错误），谈的是记忆内容的可信度，
不是记忆的所有权/身份归属。

**结论**：认知科学启发的记忆分层是一个正在升温的方向（2026 年上半年至少
3 篇独立工作），但目前唯一做得比较完整的 Human-Inspired Memory Architecture
明确建立在**服务端大模型 + 大 embedding 模型**之上，且其最"生物学"的两个
机制（engram 成熟、再巩固）**尚未在真实重复访问的个人场景下验证**——而
"个人语料会被同一用户反复引用、反复接受/拒绝补全"恰恰是端侧个人助手场景
的天然特征，是验证这些机制的理想场景，目前无人做。

## 2. Gap 陈述（一句话版本）

> 现有 LLM memory 系统要么优化"通用/多用户"场景下的检索准确率（Mem0、Zep、
> HippoRAG、MemoryOS、A-MEM），要么在认知科学对齐上做得更深但假设服务端
> 大模型可用、不考虑延迟/存储预算、且其生物学机制未在真实重复访问场景中
> 验证（Human-Inspired Memory Architecture）；**没有工作把"单一用户身份
> 关联 + 端侧毫秒级延迟/有界存储 + 生物学短长期分层"这三者作为一个联合
> 设计约束**，也没有工作在真实部署（而非合成 QA 基准）中报告满足这一联合
> 约束的实测数字。这正是最新综述（arXiv:2603.07670）十条开放问题里被
> 拆成两条却从未被合并讨论的方向。

## 3. 这个 gap 是否"真的重要"，而不只是"没人做过"

值得做的理由，对应用户故事里的产品动机：

- **端侧小模型正在变得可行**（2026 年多篇文章确认 7–9B 模型可在消费级
  设备上跑出可用体验），意味着"本地 agent 助手"不再是假设，而是正在发生
  的部署形态——这让"给端侧小模型配一个端侧记忆层"从"锦上添花"变成
  "缺失的基础设施"。
- 现有 memory 系统的成本结构（embedding 调用 + LLM 抽取/更新决策）**恰好
  和端侧场景的资源约束冲突**：如果本地模型已经是稀缺算力，memory 层不能
  再要求一次额外的模型前向传播才能给出检索结果。这不是"优化一下延迟"的
  增量问题，是架构选型问题（词法优先 vs. 语义优先）。
- 个体身份关联不是"准确率的一个子维度"，而是决定"什么该被检索"的**前提**：
  同一句"deadline 改到周五"，对系统 A 的用户和系统 B 的用户是完全不相关
  的两条记忆，但通用语义检索会因为句子本身的相似度把它们混在一起打分，
  只有身份/参与者关联能把它们正确隔离——这是个人助手场景独有、通用
  agent memory 场景（单个 agent 服务多用户或多任务）不需要显式处理的问题。

## 4. 待补研究（诚实标注）

现有 DPFM 的三个支柱已经把 gap 的前两块（身份关联、延迟/存储）用真实
系统实现和实测数据回答了；第三块（生物学短长期分层）目前是**工程近似**
（recency × heat 双衰减），还没有把"个体化"显式接进衰减/融合参数本身——
现在的 ε/η/γ/半衰期都是全局常数，不因用户而异。这是论文如果要在算法/
理论新颖性上站住脚，最值得在投稿前补的一块，详见
[2_framework_design.md](2_framework_design.md) §4 的"提议的新贡献"。
