#!/usr/bin/env bash
# Orchestrate the experiment matrix. Starts/stops llama-server between configs
# and writes one JSON per run into results/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
BASE=models/gemma-4-E2B-base-Q4_K_M.gguf
IT=models/gemma-4-E2B-it-Q4_K_M.gguf
PY=python3

start_server() {  # args: model ngl
  ./run_server.sh "$1" "$2" >"results/server_${3}.log" 2>&1 &
  SRV=$!
  # wait for health
  for _ in $(seq 1 240); do
    if curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then return 0; fi
    if ! kill -0 $SRV 2>/dev/null; then echo "server died, see results/server_${3}.log"; return 1; fi
    sleep 0.5
  done
  echo "server timeout"; return 1
}
stop_server() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; sleep 1; }

# ============ BASE model, GPU (Metal) — latency + accuracy sweep ============
echo "### starting BASE on Metal (ngl=99)"
start_server "$BASE" 99 base_gpu || exit 1

echo "### A: warm cache, greedy, n_predict=24 (main config)"
$PY harness.py --label base_warm_greedy --n-predict 24 --temp 0 \
   --out results/A_base_warm_greedy.json

echo "### B: NO prefix cache (cold prefill every request)"
$PY harness.py --label base_nocache_greedy --n-predict 24 --temp 0 --no-cache \
   --out results/B_base_nocache.json

echo "### C: short suggestion n_predict=8 (warm, greedy)"
$PY harness.py --label base_npredict8 --n-predict 8 --temp 0 \
   --out results/C_base_npredict8.json

echo "### D: longer n_predict=48, stop at paragraph (warm, greedy)"
$PY harness.py --label base_npredict48 --n-predict 48 --temp 0 --stop-para \
   --out results/D_base_npredict48.json

echo "### F: sampled temp=0.7 (accuracy/diversity tradeoff)"
$PY harness.py --label base_sampled --n-predict 24 --temp 0.7 \
   --out results/F_base_sampled.json

echo "### H: mid-cursor (edit-in-the-middle) — suffix-collision measurement (warm, greedy)"
$PY harness.py --label base_mid_cursor --n-predict 24 --temp 0 --mid-cursor \
   --out results/H_base_mid_cursor.json
stop_server

# ============ BASE model, CPU only (ngl=0) — Metal speedup baseline ========
echo "### starting BASE on CPU only (ngl=0)"
start_server "$BASE" 0 base_cpu || exit 1
echo "### E: CPU-only, warm, greedy, n_predict=24"
$PY harness.py --label base_cpu_greedy --n-predict 24 --temp 0 \
   --out results/E_base_cpu.json
stop_server

# ============ IT model, GPU — accuracy comparison (same config as A) =======
echo "### starting IT on Metal (ngl=99)"
start_server "$IT" 99 it_gpu || exit 1
echo "### G: IT model, warm, greedy, n_predict=24 (raw continuation)"
$PY harness.py --label it_warm_greedy --n-predict 24 --temp 0 \
   --out results/G_it_warm_greedy.json
stop_server

echo "### DONE. Results in results/*.json"
