#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"

ruff format .
ruff check . --fix
mypy
shellcheck scripts/*.sh
shfmt -i 2 -w scripts/*.sh
markdownlint-cli2 --config .markdownlint-cli2.jsonc \
  "README.md" \
  "CONTRIBUTING.md" \
  "docs/**/*.{md,mdx}" \
  "workloads/**/*.md"
npm run typecheck
scripts/audit-npm.sh
terraform -chdir=infra/terraform fmt -recursive
terraform -chdir=infra/terraform init -backend=false -input=false -upgrade=false >/dev/null
terraform -chdir=infra/terraform validate
