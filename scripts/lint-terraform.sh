#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"

terraform -chdir="${TERRAFORM_DIR}" fmt -check -recursive
terraform -chdir="${TERRAFORM_DIR}" init -backend=false -input=false -upgrade=false >/dev/null
terraform -chdir="${TERRAFORM_DIR}" validate
