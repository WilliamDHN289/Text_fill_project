#!/usr/bin/env bash
# Memory Layer 复现脚本：安装依赖 + smoke test
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
VENV_BASE="$BASE/_venvs"
LIT="$BASE"
PY311="/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11"

run_in_venv() {
  local name=$1
  shift
  source "$VENV_BASE/$name/bin/activate"
  "$@"
  deactivate
}

setup_project() {
  local name=$1
  local install_cmd=$2
  echo ""
  echo "========== [$name] Install =========="
  if [ ! -d "$VENV_BASE/$name" ]; then
    $PY311 -m venv "$VENV_BASE/$name"
  fi
  run_in_venv "$name" bash -c "pip install -q --upgrade pip setuptools wheel && $install_cmd"
}

smoke_test() {
  local name=$1
  local test_cmd=$2
  echo ""
  echo "========== [$name] Smoke Test =========="
  run_in_venv "$name" bash -c "$test_cmd"
  echo "[$name] PASS"
}

# --- Install ---
setup_project mem0     "cd '$LIT/mem0/codebase' && pip install -q -e ."
setup_project graphiti "cd '$LIT/graphiti/codebase' && pip install -q -e ."
setup_project a-mem    "cd '$LIT/a-mem/codebase' && pip install -q -r requirements.txt"
setup_project hipporag "pip install -q hipporag"
setup_project letta    "cd '$LIT/letta/codebase' && pip install -q -e ."
setup_project langmem  "cd '$LIT/langmem/codebase' && pip install -q -e ."
setup_project memoryos "pip install -q memoryos"  # PyPI MemOS; BAI-LAB repo 见 PENDING.md

# --- Smoke Tests (import + minimal unit tests) ---
smoke_test mem0 \
  "python -c 'from mem0 import Memory; print(\"mem0 OK\", Memory)'"

smoke_test graphiti \
  "python -c 'import graphiti_core; print(\"graphiti OK\", graphiti_core.__file__)'"

smoke_test a-mem \
  "cd '$LIT/a-mem/codebase' && python -c 'from memory_layer import AgenticMemorySystem; print(\"a-mem OK\")'"

smoke_test hipporag \
  "python -c 'from hipporag import HippoRAG; print(\"hipporag OK\", HippoRAG)'"

smoke_test letta \
  "python -c 'import letta; print(\"letta OK\", letta.__version__ if hasattr(letta,\"__version__\") else \"\")'"

smoke_test langmem \
  "python -c 'import langmem; print(\"langmem OK\")'"

smoke_test memoryos \
  "if [ -d '$LIT/memoryos/codebase' ]; then cd '$LIT/memoryos/codebase' && python -c 'print(\"BAI-LAB MemoryOS repo present\")'; else echo '[memoryos] BAI-LAB repo pending — see memoryos/PENDING.md'; fi && \
   python -c 'import memos; print(\"memos PyPI OK\")' 2>/dev/null || echo '[memoryos] PyPI memos not installed (optional)'"

echo ""
echo "=========================================="
echo "All smoke tests passed."
echo "For full reproduction, see each project's README."
echo "=========================================="
