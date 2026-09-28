#!/usr/bin/env bash
# Fetch the llama.cpp prebuilt binary and both model GGUFs. Idempotent-ish.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p bin models results

if [ ! -x bin/llama-b9654/llama-server ]; then
  curl -sSL -o bin/llama.tar.gz \
    https://github.com/ggml-org/llama.cpp/releases/download/b9654/llama-b9654-bin-macos-arm64.tar.gz
  tar -C bin -xzf bin/llama.tar.gz
  xattr -dr com.apple.quarantine bin/llama-b9654 || true
fi

[ -f models/gemma-4-E2B-base-Q4_K_M.gguf ] || curl -sSL -o models/gemma-4-E2B-base-Q4_K_M.gguf \
  https://huggingface.co/mradermacher/gemma-4-E2B-GGUF/resolve/main/gemma-4-E2B.Q4_K_M.gguf

[ -f models/gemma-4-E2B-it-Q4_K_M.gguf ] || curl -sSL -o models/gemma-4-E2B-it-Q4_K_M.gguf \
  https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf

echo "OK"
