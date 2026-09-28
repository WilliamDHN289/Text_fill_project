#!/bin/sh
# Public corpora used by exp_real.py. Neither is redistributed with this code.
set -e
cd "$(dirname "$0")"
curl -L -o longmemeval_oracle.json \
  "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_oracle.json"
curl -L -o locomo10.json \
  "https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json"
echo "fetched: $(ls -1 *.json | tr '\n' ' ')"
