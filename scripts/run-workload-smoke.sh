#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"

export RAY_TRAIN_V2_ENABLED=1

python3 workloads/deepspeed_finetune/train.py \
  --profile smoke \
  --cpu-only \
  --evidence-dir "${ROOT_DIR}/.cache/workloads/deepspeed_finetune/smoke"
