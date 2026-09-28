# MemoryOS (BAI-LAB) — 待下载

论文: [arXiv:2506.06326](https://arxiv.org/abs/2506.06326)  
官方仓库: https://github.com/BAI-LAB/MemoryOS

## 状态

GitHub 当前网络不可达，完整仓库尚未下载。请在本机 GitHub 可用时运行：

```bash
cd /Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/1_literature
bash download_missing.sh
```

或手动 clone：

```bash
git clone --depth 1 https://github.com/BAI-LAB/MemoryOS.git memoryos/codebase
```

## 注意

PyPI 上的 `memoryos` 包是 **MemOS (openmem.net)**，与 BAI-LAB 论文项目 **不是同一个项目**。请勿混淆。

## 复现（仓库下载后）

参考官方 README：

```bash
cd codebase
pip install -r requirements.txt
python eval/*.py   # 以仓库 README 为准
```
