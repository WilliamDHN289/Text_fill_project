#!/usr/bin/env bash
# 补全 GitHub 完整仓库（需可访问 GitHub 或 gitclone.com 镜像）
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
MIRROR="${GITHUB_MIRROR:-https://gitclone.com/github.com}"

clone_repo() {
  local folder="$1"
  local repo="$2"
  local dest="$BASE/$folder/codebase"
  echo ">>> Cloning $repo -> $dest"
  rm -rf "$dest"
  git clone --depth 1 "${MIRROR}/${repo}.git" "$dest" || \
  git clone --depth 1 "https://github.com/${repo}.git" "$dest"
}

clone_repo letta     "letta-ai/letta"
clone_repo hipporag  "OSU-NLP-Group/HippoRAG"
clone_repo langmem   "langchain-ai/langmem"
clone_repo memoryos  "BAI-LAB/MemoryOS"

echo "Done. Re-run reproduce_all.sh to verify."
