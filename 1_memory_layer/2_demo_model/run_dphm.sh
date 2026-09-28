#!/usr/bin/env bash
# Run DPHM vs base comparison. Starts llama-server if not already up.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
PY=python3
CFG=config.yaml
MODEL=$(grep '^  model:' "$CFG" | awk '{print $2}' | tr -d '"')
NGL=$(grep '^  ngl:' "$CFG" | awk '{print $2}')

if ! curl -sf http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then
  echo "### starting llama-server ($MODEL, ngl=$NGL)"
  ./run_server.sh "$MODEL" "$NGL" > results/server_dphm.log 2>&1 &
  SRV=$!
  for _ in $(seq 1 120); do
    if curl -sf http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then break; fi
    sleep 1
  done
  STARTED=1
else
  STARTED=0
fi

echo "### DPHM vs base (email passage)"
$PY harness_dphm.py --config "$CFG" --out results/I_dphm_compare.json

echo "### DONE -> results/I_dphm_compare.json"
if [ "$STARTED" = 1 ]; then
  kill $SRV 2>/dev/null || true
fi
