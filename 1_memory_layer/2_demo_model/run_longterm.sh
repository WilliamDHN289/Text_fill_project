#!/usr/bin/env bash
# Full long-term DPHM experiment: corpus -> 30-session simulation -> figures.
# Starts llama-server if not already up.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
PY=python3
CFG=config.yaml
MODEL=$(grep '^  model:' "$CFG" | awk '{print $2}' | tr -d '"')
NGL=$(grep '^  ngl:' "$CFG" | awk '{print $2}')

mkdir -p results

if [ ! -f data/user_corpus.json ]; then
  echo "### building corpus from public data (Enron + Gutenberg)"
  $PY fetch_corpus.py
fi

if ! curl -sf http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then
  echo "### starting llama-server ($MODEL, ngl=$NGL)"
  ./run_server.sh "$MODEL" "$NGL" > results/server_longterm.log 2>&1 &
  SRV=$!
  for _ in $(seq 1 120); do
    if curl -sf http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then break; fi
    sleep 1
  done
  STARTED=1
else
  STARTED=0
fi

echo "### long-term user simulation (base vs DPHM)"
$PY simulate_longterm.py --config "$CFG" --out results/longterm_sim.json \
  2>&1 | tee results/longterm_sim.log

echo "### rendering figures"
$PY visualize.py --in results/longterm_sim.json

echo "### DONE -> results/longterm_sim.json, results/figures/"
if [ "$STARTED" = 1 ]; then
  kill $SRV 2>/dev/null || true
fi
