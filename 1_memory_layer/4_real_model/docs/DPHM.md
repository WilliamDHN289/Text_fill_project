# DPHM — Dual-Path Habit Memory

FlowIn 的低延迟个人记忆层（`3_dphm/dphm.py` 参考实现的 Swift 移植 + 产品集成）。

## 核心思想

补全场景的「记忆」≠ 对话场景的「记忆」：对话记忆存事实、需要语义检索；补全记忆存**语言习惯**（高频搭配、个人术语、中英 code-switching、句式模板）——本质是一个个人化统计语言模型，keystroke 时不需要 ANN 检索。

三条设计原则：

1. **读写路径彻底解耦**。Hot path（每次 keystroke 的 `suggest()`）只做 O(1) 哈希/trie 查找——零 embedding、零 ANN、零 LLM，目标 p99 < 5ms。Cold path（`DPHMConsolidator`，后台队列）做习惯抽取、collocation 挖掘（decayed count × PMI）、记忆巩固与遗忘（prune）、持久化，结果编译成 hot path 直接可查的数据结构。
2. **习惯 = 带遗忘的个人 n-gram 缓存 + shallow fusion**。长期 trie（慢衰减，默认半衰期 30 天）+ session trie（快衰减，默认 15 分钟），Stupid Backoff 打分，融合：`score = λ_long·s_long + λ_sess·s_sess + β·prefetch_boost`。理论来源：Cache LM (Kuhn & De Mori 1990)、Neural Cache (arXiv:1612.04426)、kNN-LM (arXiv:1911.00172)、shallow fusion (arXiv:1503.03535)、Stupid Backoff (Brants 2007)、Ebbinghaus 遗忘曲线巩固 (MemoryBank, arXiv:2305.10250)。
3. **Speculative prefetch**。语义级检索由词边界（debounce 150ms）异步触发，写入 `PrefetchBuffer`；下一次 keystroke 的 hot path 只是读缓存。默认检索器是轻量词法检索（近期 commit 环形缓冲），可整体换成 embedding+ANN 而不动 hot path。

## 代码结构

| 文件 | 职责 |
|---|---|
| `Sources/DPHMemory/DPHMTokenizer.swift` | 中英双语分词（英文整词、CJK 逐字）+ detokenize |
| `Sources/DPHMemory/DecayedNGramTrie.swift` | 惰性衰减 n-gram trie、Stupid Backoff、prune、快照 |
| `Sources/DPHMemory/HabitLexicon.swift` | 已巩固的多词习惯短语库（anchor token → O(1) 取候选） |
| `Sources/DPHMemory/SpeculativePrefetch.swift` | PrefetchBuffer + 防抖后台检索 |
| `Sources/DPHMemory/DPHMConsolidator.swift` | 后台巩固管线（观察→挖掘→遗忘→持久化） |
| `Sources/DPHMemory/DPHMMemory.swift` | Facade：`suggest` / `onWordBoundary` / `commit*` / `rankCandidates` |
| `Sources/DPHMemory/DPHMConfig.swift` | dphm.yaml 加载 + 极简 YAML 解析 |

## 与 Engine 的接入点（`Sources/Autocomplete/Engine/Engine.swift`）

- **学习信号（cold path，全异步）**：
  - 发送消息确认（`confirmSentMessage` / `captureLastObservedAsSentMessage`）→ `commitSentMessage`（权重 1.0，最强信号）
  - Tab/backtick 接受建议（`acceptWord` / `acceptFull`）→ `commitAcceptedSuggestion`（权重 0.6）
- **词边界事件**：空格 keystroke → `onWordBoundary`（session trie 内联观察 ~40µs + 预取通知）
- **即时习惯 ghost text（hot path）**：字符 keystroke 后、LLM 请求发出前，`suggest()` 命中且过分数线 → 立刻显示 ghost text（µs 级），LLM 结果返回后自然替换。桥接了 debounce + 推理的数百 ms 空窗。
- **云端 3 选 1 重排**（默认关）：`fusion.rerank_cloud_candidates: true` 时按习惯亲和度重排候选，需超出 `rerank_margin` 才替换首选。
- **持久化**：后台每 `save_interval_s` 快照到 `~/Library/Application Support/Autocomplete/dphm_store.json`；退出时 `saveNow()` 强制落盘。

## 参数调整

编辑 `~/Library/Application Support/Autocomplete/dphm.yaml`（首次运行自动生成；仓库根目录的 `dphm.yaml` 是同内容模板），重启 App 生效。也可用 `DPHM_CONFIG=/path/to/dphm.yaml` 覆盖位置。所有键的含义见文件内注释。

最常调的几个：

- `hot_path.min_display_score`（默认 -3.5）：调低显示更多习惯建议、调高更保守
- `hot_path.display_enabled`：只想要学习/重排、不要即时 ghost text 时设 false
- `long_term.half_life_days` / `session.half_life_minutes`：遗忘速度
- `fusion.rerank_cloud_candidates`：开启云端候选重排

## 测试与基准

```bash
./scripts/test-dphm.sh          # 25 个测试：单元 + 端到端习惯学习 + 延迟基准
```

本机（M 系列，debug 构建）实测：

```
suggest()       n=2000  mean=24µs  p50=12µs  p95=71µs  p99=82µs  max=102µs   （预算 5ms，余量 ~60x）
onWordBoundary  p50=38µs  p99=50µs
```
