# HippoRAG — 源码说明

论文: [arXiv:2405.14831](https://arxiv.org/abs/2405.14831)  
官方仓库: https://github.com/OSU-NLP-Group/HippoRAG

## 当前 codebase

`codebase/` 来自 PyPI `hipporag` v2.0.0a4（HippoRAG 2 库版本），可用于：

```python
from hipporag import HippoRAG
```

## 论文实验复现

完整实验脚本（`main.py`、`reproduce/` 等）需 clone 完整 GitHub 仓库：

```bash
bash ../download_missing.sh
# 或
git clone --depth 1 https://github.com/OSU-NLP-Group/HippoRAG.git codebase_full
cd codebase_full
conda create -n hipporag python=3.10
pip install -r requirements.txt
python main.py
```

Legacy (HippoRAG 1) 分支: https://github.com/OSU-NLP-Group/HippoRAG/tree/legacy
