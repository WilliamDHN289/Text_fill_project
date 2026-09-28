#!/usr/bin/env bash
# Start llama-server for a given model. Usage: ./run_server.sh <model.gguf> [ngl]
# ngl = number of layers to offload to the Metal GPU (default 99 = all).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/bin/llama-b9654"
MODEL="${1:?usage: run_server.sh <model.gguf> [ngl]}"
NGL="${2:-99}"

export DYLD_LIBRARY_PATH="$BIN"
exec "$BIN/llama-server" \
  -m "$MODEL" \
  --host 127.0.0.1 --port 8080 \
  -ngl "$NGL" \
  -c 2048 \
  -t 4 \
  --no-warmup \
  -fa on
