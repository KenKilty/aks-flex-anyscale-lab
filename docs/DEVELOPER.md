---
title: Developer Guide
sidebar_position: 99
---

This guide explains the lab structure, the tooling path, and the checks to run before a live Azure end-to-end test.

## Project Structure

| Path | Purpose |
| --- | --- |
| `docs/ai-workloads-on-aks/` | Student workshop modules and SVG architecture assets |
| `infra/terraform/` | Public AKS, Flex host, storage, ACR, identity, observability, networking, and Anyscale Platform resources |
| `scripts/` | Operator entrypoints, E2E harness, module gates, proof helpers, and cleanup logic |
| `scripts/lib/` | Shared Bash libraries used by gates and workload helpers |
| `workloads/deepspeed_finetune/` | Ray Train + DeepSpeed proof workload and proof-summary validator |
| `src/` | Docusaurus React/CSS customizations |
| `.env-template` | Committed deployment variable contract; copy to ignored `.env` for local runs |

## Technical Stack

| Area | Tools |
| --- | --- |
| Documentation | Docusaurus 3, MDX, Mermaid, SVG assets |
| Infrastructure | Terraform, AzureRM provider, AzAPI provider |
| Azure services | AKS, AKS Flex Node, Azure CNI, Gateway API app routing, ACR, Storage, Managed Identity, Log Analytics |
| Anyscale | Anyscale on Azure Platform cloud, AKS marketplace extension, Anyscale CLI, Ray Jobs |
| Workload | Python, Ray Train, DeepSpeed, PyTorch, Azure Blob proof storage through workload identity |
| Validation | Bash gates, `jq`, `kubectl`, Azure CLI, Terraform validate, TypeScript, markdownlint, ruff, mypy, npm audit |

## Lab Flow

The student path is module-based, and the E2E harness maps directly to those modules:

| Module | E2E phase | Main scripts |
| --- | --- | --- |
| 1-2 Environment + AKS foundation | `foundation` | `scripts/anyscale-aks.sh doctor`, `scripts/anyscale-aks.sh apply`, `scripts/validate-lab-gates.sh m2` |
| 3 Flex Node | `flex` | `scripts/anyscale-aks.sh flex-config`, `scripts/anyscale-aks.sh flex-bootstrap`, `scripts/validate-lab-gates.sh m3` |
| 4 Anyscale binding | `anyscale` | Terraform `anyscale.tf`, AKS extension, `scripts/validate-lab-gates.sh m4` |
| 5 Preflight | `autoscale` | `scripts/install-nvidia-device-plugin.sh`, `scripts/validate-lab-gates.sh m5` |
| 6 Proof | `proof-remote` | `scripts/run-anyscale-proof.sh --mode both` |
| 7 Teardown | `teardown` | `scripts/anyscale-aks.sh destroy`, `scripts/validate-lab-gates.sh teardown` |

Use `scripts/run-lab-e2e.sh all` for a full live run. Use individual phases when resuming after a targeted fix.

## Environment Files

Create a local `.env` from the template:

```bash
cp .env-template .env
```

The setup helper renders `TF_VAR_*` values into `infra/terraform/terraform.auto.tfvars.json`. Both `.env` and rendered Terraform state/plan files are ignored and must not be committed.

Important GPU settings:

```bash
TF_VAR_flex_host_vm_size="Standard_NC16as_T4_v3"
TF_VAR_flex_host_source_image_reference='{"publisher":"microsoft-dsvm","offer":"ubuntu-hpc","sku":"2204","version":"latest"}'
ANYSCALE_FLEX_GPU_ENABLED="true"
ANYSCALE_PROOF_GPU_ACCELERATOR_TYPE="T4"
ANYSCALE_PROOF_GPU_PRODUCT_LABEL="NVIDIA-T4"
ANYSCALE_PROOF_GPU_TARGET="flex"
ANYSCALE_PROOF_GPU_WORKER_COUNT="1"
```

Important Anyscale user RBAC setting:

```bash
TF_VAR_anyscale_platform_default_admin_assignment='{"enabled":true,"principal_type":"User","role_definition_name":"Anyscale Platform Administrator","scope":"subscription"}'
```

## Local Documentation Development

Install dependencies:

```bash
npm install
```

Start the Docusaurus dev server using the repository helper:

```bash
scripts/docs-dev.sh
```

The helper clears Docusaurus cache and restarts port 3000. Use it instead of calling `npm start` directly.

Validate the production build:

```bash
npm run build
```

## Validation Commands

Run fast focused checks while editing:

```bash
bash -n scripts/validate-lab-gates.sh
bash -n scripts/run-lab-e2e.sh
bash -n scripts/run-anyscale-proof.sh
terraform -chdir=infra/terraform validate
markdownlint-cli2 --config .markdownlint-cli2.jsonc docs/**/*.mdx README.md
```

Run the repository gate before committing:

```bash
scripts/lint.sh
npm run build
```

`scripts/lint.sh` covers Python formatting/checks, shell checks, markdown/MDX, TypeScript, npm audit, and Terraform validation. The npm audit gate can pass with reviewed exceptions listed in `scripts/audit-npm.sh`.

## Live E2E Testing

Before a live E2E, confirm the baseline is clean:

```bash
terraform -chdir=infra/terraform state list
source .env
az group exists --subscription "$TF_VAR_azure_subscription_id" --name "rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
```

Expected clean baseline:

```text
false
```

Run a full E2E:

```bash
./scripts/run-lab-e2e.sh all
```

Resume from a phase after fixing a targeted issue:

```bash
./scripts/run-lab-e2e.sh autoscale
./scripts/run-lab-e2e.sh proof-remote
./scripts/run-lab-e2e.sh teardown
```

Proof artifacts are written under `.cache/anyscale/proofs/`. Validate summaries directly:

```bash
python3 workloads/deepspeed_finetune/validate_proof_summary.py \
  .cache/anyscale/proofs/<proof-name>-proof-summary.json
```

Placement proof comes from `<proof-name>-kubernetes-placement.json`. For GPU success, the worker pod must be on `agentpool=aksflexnodes` in the Flex region and the proof summary must report `cuda_available=true` with `device_name="Tesla T4"`.

## Troubleshooting Patterns

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Module 4 operator crash says gateway address missing | Extension rendered gateway config without an address | Configure both `networking.gateway.hostname` and `networking.gateway.ip` |
| Module 4 RBAC gate fails | Current Azure principal lacks Anyscale Platform role | Keep `TF_VAR_anyscale_platform_default_admin_assignment` enabled or pre-create equivalent role assignment |
| Module 5 GPU gate has no allocatable GPU | NVIDIA device plugin not ready or Flex host lacks driver | Use the GPU host image, run `scripts/install-nvidia-device-plugin.sh`, and wait for allocatable `nvidia.com/gpu` |
| GPU worker Pending with `nvidia.com/gpu.product=NVIDIA-T4` selector | Flex node lacks product label | Re-run `scripts/install-nvidia-device-plugin.sh` |
| Anyscale console shows Jobs but no Workspaces | Proofs use Anyscale Jobs, not Workspaces | Expected behavior |
| Old Azure Anyscale cloud remains in Anyscale console after Azure cleanup | Stale control-plane registration with no backing ARM resource | Provider-side cleanup is required; `anyscale cloud delete` is unsupported for Azure clouds |

## Cleanup

Always run teardown after live tests:

```bash
./scripts/run-lab-e2e.sh teardown
terraform -chdir=infra/terraform state list
```

A successful teardown prints `PASS M7-01 resource group deleted` and `PASS M7-02 terraform state empty`.
