# Memory Layer Literature & Codebases

主流 Memory Layer 设计论文与代码库归档目录。每个子目录包含 `paper.pdf`（或官方文档）与 `codebase/`。

## 目录结构

| 目录 | 系统 | 论文/来源 | Codebase 来源 | 状态 |
|------|------|-----------|---------------|------|
| [mem0/](mem0/) | Mem0 | [arXiv:2504.19413](https://arxiv.org/abs/2504.19413) | GitHub 完整仓库 | ✅ 完整 |
| [graphiti/](graphiti/) | Zep / Graphiti | [arXiv:2501.13956](https://arxiv.org/abs/2501.13956) | GitHub 完整仓库 | ✅ 完整 |
| [letta/](letta/) | Letta (MemGPT) | [arXiv:2310.08560](https://arxiv.org/abs/2310.08560) | PyPI sdist (v0.16.8) | ⚠️ 源码包（非完整 git） |
| [a-mem/](a-mem/) | A-MEM | [arXiv:2502.12110](https://arxiv.org/abs/2502.12110) | GitHub 完整仓库 | ✅ 完整 |
| [hipporag/](hipporag/) | HippoRAG | [arXiv:2405.14831](https://arxiv.org/abs/2405.14831) | PyPI sdist (v2.0.0a4) | ⚠️ 库版本（论文复现需完整 repo） |
| [langmem/](langmem/) | LangMem | [LangChain 文档](https://langchain-ai.github.io/langmem/) | PyPI sdist (v0.0.30) | ⚠️ 源码包 + 官方文档 |
| [memoryos/](memoryos/) | MemoryOS (BAI-LAB) | [arXiv:2506.06326](https://arxiv.org/abs/2506.06326) | 待下载 | ❌ 需手动 clone |

## 复现

```bash
cd /Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/1_literature
bash reproduce_all.sh          # 安装依赖 + 运行 smoke tests
bash download_missing.sh       # 补全未下载的 GitHub 仓库（需 GitHub 网络）
```

各项目独立虚拟环境位于 `_venvs/<project>/`。

## 网络说明

当前环境 GitHub HTTPS 直连超时，已通过 `gitclone.com` 镜像或 PyPI 源码包获取部分仓库。若需完整 git 历史或论文实验脚本，请在 GitHub 可访问时运行 `download_missing.sh`。

## 引用

各项目 README 与 paper.pdf 内含 BibTeX。
