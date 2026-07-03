#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "${ROOT_DIR}/workloads/deepspeed_finetune/validate_proof_summary.py" \
  "${ROOT_DIR}/workloads/deepspeed_finetune/sample-proof-summary.json"
