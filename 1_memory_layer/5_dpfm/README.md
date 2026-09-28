# DPFM: Dual-Path Fact Memory

面向实时文本补齐（text_fill）的**事实记忆层**。DPHM（`../3_dphm/`）的后继设计：
DPHM 记的是**语言习惯**（个人 n-gram，score-level 融合）；DPFM 记的是**事实**
（过去写过什么、写给谁、什么时候），检索后**注入 prompt**。

```
写路径(冷):  文档 → 事实抽取 → 去重/取代 → BM25F 倒排索引 + 实体共现图
读路径(热):  输入上下文 ──(与 text_fill 并行)──> 焦点词查询
             → BM25F top-k × recency × heat + 实体图联想 → prompt block
```

## 1. 问题定位的修正

| | DPHM（旧假设） | DPFM（新需求） |
|---|---|---|
| 记忆内容 | 语言习惯（搭配、句式模板） | 事实（邮件内容、收件人、承诺、日期） |
| 消费方式 | 与 base LM 做 shallow fusion（改分数） | 检索 → 写入 prompt（改输入） |
| 单位 | (context → next_token) 计数 | 原子事实句 + 实体链接 + 时态 |

两者**不冲突**：DPHM 的习惯层仍可做 score fusion，DPFM 的事实层做 prompt
injection，是同一产品的两个正交记忆通道。且 DPHM 的架构骨架（冷热路径分离、
惰性衰减计数器、speculative prefetch）在 DPFM 中被完整保留。

## 2. 文献映射（`../1_literature/`）

| 系统 | 借鉴的机制 | 在 DPFM 中的形态 |
|---|---|---|
| **Mem0** (2504.19413) | 两段式写入：Extract → Update(ADD/UPDATE/DELETE/NOOP) | `_admit()`: 规则版决策——近重复→NOOP+强化；同 key→取代；否则→ADD。LLM 抽取器可插拔替换规则抽取器 |
| **Zep/Graphiti** (2501.13956) | ① BM25 与 cosine 是并列的一等检索器，RRF 融合；② 双时态边：新事实 *invalidate* 旧事实而非删除 | ① 以 BM25F 为主检索器，embedding 降级为可选 backup，RRF 融合（`_rrf_fuse`）；② `Fact.valid_from / invalid_at` + `key_owner` 槽位取代 |
| **HippoRAG** (2405.14831) | 实体图 + Personalized PageRank 做联想式多跳召回 | `EntityGraph`: 衰减共现图 + **截断 1-hop 扩散激活**（PPR 的 O(seeds×degree) 近似），无需 embedding 即可召回"和 Alice 相关的 Phoenix 事项" |
| **MemoryOS** (2506.06326) | heat 驱动的分层晋升/淘汰 | `Fact.heat`（14 天半衰期衰减计数器）：被采纳的补全强化其来源事实；遗忘时 `recency × (1+heat)` 低于阈值才删除 |
| **A-MEM** (2502.12110) | Zettelkasten 原子笔记 + 自动链接 | 事实 = 原子句子；链接 = 实体共现图（隐式，无需 LLM 建链） |
| **Letta/MemGPT** (2310.08560) | core memory / archival memory 分层 | `kind='profile'` 事实免于遗忘（pinned），episodic/semantic 参与淘汰 |
| **DPHM**（自研） | 冷热路径分离、惰性衰减、speculative prefetch、consolidation | 架构骨架原样保留；consolidation 信号从"n-gram 复现"换成"事实被重复观察 / 被采纳的补全使用" |

## 3. 数据模型

```python
Fact(text,                 # 原子的、prompt-ready 的事实句
     entities,             # 归一化实体（谁/什么）→ 倒排字段 + 图节点
     participants,         # 文档的收件人/对话方 → 倒排字段（强信号）
     kind,                 # episodic / semantic / profile
     key,                  # 可选槽位 ('phoenix','launch_date')，同 key 取代
     valid_from/invalid_at,# 双时态：被取代的事实不可检索但不销毁
     last_reinforced, heat)# recency 与使用强化
```

## 4. 检索打分

查询构造（`_build_query`）：取光标前窗口的 index terms，**位置衰减加权**
（λ^d，离光标越近权重越高，λ=0.95）+ 收件人词强加权（+1.5），去停用词后按
`weight × idf` 剪枝到 12 个词（WAND 思想的预算化，界定 posting list 工作量）。
中文额外产出**字 bigram** 词项（单字近似停用词，bigram 才有区分度）。

打分融合：

```
score(f) = BM25F(q,f) · (ε + (1−ε)·2^(−Δt/T_rec)) · (1 + η·heat(f))
         + γ · assoc(f)
```

- **BM25F**：simple-BM25F（字段加权 tf 合并后做 BM25 饱和），字段权重
  text=1.0 / entities=2.5 / participants=2.0。纯词法——补全恰恰需要**逐字拷贝**
  名字、日期、数字，词法精确匹配比语义相似更对口。
- **recency**：30 天半衰期，带下限 ε=0.15（老事实词法强匹配时仍可召回）。
- **heat**：`mark_used(fact_ids)` 在用户采纳补全时调用，闭环强化。
- **assoc**：实体图扩散激活，捕捉"上下文没提但相关"的事实（联想召回）。
- 类比 Stupid Backoff 的取舍：不是平滑概率，但对 ranking 够用、计算便宜。

## 5. 延迟设计（需求 1）

热路径全部是内存 dict 操作：≤12 个查询词 × 个人语料的短 posting list，
term-at-a-time 累加 + heap top-k。实测（M 系列 Mac，单线程，20k facts）：

```
retrieve p50 = 1.8 ms   p95 = 2.2 ms   p99 = 2.4 ms
```

比 LLM prefill 低两个数量级，可以内联在 text_fill 请求路径里，也可以并行。

## 6. 与 text_fill 并行（需求 2）

两种模式，二选一或叠加：

1. **Speculative prefetch**（延续 DPHM）：编辑器在词边界/停顿时调
   `poke_prefetch(context, participants)`（去抖、latest-wins、永不阻塞）；
   后台线程检索并原子发布 `RetrievalSnapshot`。text_fill 触发时
   `snapshot()` 一次属性读取拿到 prompt block——**零等待**，接受轻微陈旧。
2. **Deadline race**：`retrieve_with_deadline(ctx, deadline_s=0.02)` 与
   text_fill 的网络/prefill 并发起跑；预算内完成用新结果，超时回退到
   prefetch 快照（标记 `stale=True`），**永不阻塞补全**。

## 7. Embedding 作为 backup（需求 3）

构造时传 `semantic_fn(context, k) -> [(fact_text, score)]`：
- 只在 prefetch 线程 / 完整 `retrieve` 中执行，deadline 路径不等它；
- 结果与词法排序做 **RRF 融合**（Zep 同款，秩融合免调分数量纲）；
- 不传则系统纯词法运行，行为不变——embedding 是加法项，不是地基。

## 8. 写路径与遗忘（冷路径）

- `observe_document(source_id, text, participants)`：入队即返回，挂在
  应用的保存/发送钩子上。后台 consolidator 抽取→去重→建索引→更新图。
- 默认规则抽取器：句切分 + 实体检测（邮箱/日期/大写序列/**gazetteer**，
  中文实体无大写信号必须走 gazetteer 或换 LLM 抽取器）+ 事实信号词过滤。
  升级路径：把 `extractor` 换成 LLM 批量抽取（Mem0 式），同时产出 `key`
  槽位使矛盾事实自动取代（规则抽取器不产 key，旧新事实会并存）。
- 遗忘：`request_prune()` 周期触发，`recency × (1+heat) < 阈值` 或已失效的
  事实删除（profile 除外），同时给图剪枝——内存有界。

## 9. 文件

- [dpfm.py](dpfm.py) — 主模块，stdlib-only，约 600 行
- [demo.py](demo.py) — 端到端演示 + 20k facts 延迟基准（`python3 demo.py`）

## 10. 已知局限 / 下一步

1. 规则抽取器召回一般、不产 `key`——矛盾事实（旧 deadline）会共存于 prompt，
   靠 recency 排序缓解；接 LLM 抽取器（冷路径，成本可摊）是正解。
2. 中文实体依赖 gazetteer；可从用户通讯录/文件名自动构建。
3. 无持久化；facts/postings 均为普通 dict，加 pickle/sqlite 快照即可。
4. `semantic_fn` 的 fact 匹配走 text 精确对齐，接真实向量库时应改为按 fact_id。
