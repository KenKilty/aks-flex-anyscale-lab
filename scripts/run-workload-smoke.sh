#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_HASH="$(printf '%s' "${ROOT_DIR}" | cksum | awk '{print $1}')"
VENV_DIR="${ANYSCALE_SMOKE_VENV_DIR:-${TMPDIR%/}/aks-flex-anyscale-smoke-${WORKSPACE_HASH}}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

ensure_local_venv() {
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
  fi

  "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
  "${VENV_DIR}/bin/python" -m pip install \
    torch \
    deepspeed \
    ninja \
    'ray[default,train]' \
    transformers >/dev/null
}

cd "${ROOT_DIR}"

export RAY_TRAIN_V2_ENABLED=1
export DS_ACCELERATOR=cpu

need_cmd python3
ensure_local_venv
export PATH="${VENV_DIR}/bin:${PATH}"

"${VENV_DIR}/bin/python" workloads/deepspeed_finetune/train.py \
  --profile smoke \
  --cpu-only \
  --zero-stage 0 \
  --evidence-dir "${ROOT_DIR}/.cache/workloads/deepspeed_finetune/smoke"
