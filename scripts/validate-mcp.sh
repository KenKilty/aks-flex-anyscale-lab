#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_CONFIG="${ROOT_DIR}/.vscode/mcp.json"

print_section() {
  printf '\n== %s ==\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

print_section "Validate config file"
if [[ ! -f "${MCP_CONFIG}" ]]; then
  printf 'missing MCP config: %s\n' "${MCP_CONFIG}" >&2
  exit 1
fi
printf 'found: %s\n' "${MCP_CONFIG}"

print_section "Validate local commands"
require_cmd npx
require_cmd aks-mcp
printf 'npx: %s\n' "$(command -v npx)"
printf 'aks-mcp: %s\n' "$(command -v aks-mcp)"

print_section "Validate Playwright MCP package"
PLAYWRIGHT_VERSION="$(npx -y @playwright/mcp@latest --version)"
printf 'playwright-mcp version: %s\n' "${PLAYWRIGHT_VERSION}"

print_section "Validate Azure MCP package"
AZURE_MCP_VERSION="$(npx -y @azure/mcp@3.0.0-beta.22 --version)"
printf 'azure-mcp version: %s\n' "${AZURE_MCP_VERSION}"

print_section "Validate AKS MCP binary"
AKS_MCP_VERSION="$(aks-mcp --version | head -n 1)"
printf 'aks-mcp: %s\n' "${AKS_MCP_VERSION}"

print_section "Validate AKS MCP startup args"
aks-mcp \
  --transport stdio \
  --access-level readonly \
  --enabled-components az_cli,monitor,fleet,network,compute,detectors,advisor,kubectl \
  --help >/dev/null
printf 'aks-mcp startup args: valid\n'

print_section "Validate Azure authentication context"
az account show --query '{subscription:id, tenant:tenantId, user:user.name}' -o json

print_section "Done"
printf 'MCP prerequisites are present and CLI-level checks passed.\n'
