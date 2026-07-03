#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./scripts/anyscale-aks.sh COMMAND

Commands:
  doctor           Check local dependencies and Azure CLI context.
  status           Show Azure context and current Terraform outputs.
  render-tfvars    Render infra/terraform/terraform.auto.tfvars.json from .env.
  init             Run terraform init.
  validate         Run terraform validate.
  test             Run terraform test.
  plan             Render tfvars, init, validate, and create tfplan.
  apply            Render tfvars, init, validate, test, and apply.
  destroy          Render tfvars, init, and destroy.
  output           Print terraform outputs.
  flex-config      Generate an AKS Flex Node config for the provisioned host.
  flex-bootstrap   Copy config to the provisioned Flex host and start aks-flex-node.

Environment:
  ANYSCALE_AKS_ENV_FILE
      Optional alternate env file. Use this to point at a different env file
      (formatted like .env-template) without editing the default .env.
USAGE
}

command="${1:-}"

case "${command}" in
doctor | status | render-tfvars | init | validate | test | plan | apply | destroy | output | flex-config | flex-bootstrap)
  exec "${SCRIPT_DIR}/setup.sh" "${command}"
  ;;
"" | -h | --help | help)
  usage
  ;;
*)
  printf 'error: unknown command %s\n' "${command}" >&2
  usage >&2
  exit 1
  ;;
esac
