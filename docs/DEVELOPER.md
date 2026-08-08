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
| `scripts/` | Operator entrypoints, E2E harness, module gates, workload helpers, and cleanup logic |
| `scripts/lib/` | Shared Bash libraries used by gates and workload helpers |
| `workloads/deepspeed_finetune/` | Ray Train + DeepSpeed workload and workload-summary validator |
| `src/` | Docusaurus React/CSS customizations |
| `.env-template` | Committed deployment variable contract; copy to ignored `.env` for local runs |
| `requirements-tooling.txt` | Pinned Anyscale CLI used by bootstrap and workload scripts |

## Technical Stack

| Area | Tools |
| --- | --- |
| Documentation | Docusaurus 3, MDX, Mermaid, SVG assets |
| Infrastructure | Terraform, AzureRM provider, AzAPI provider |
| Azure services | AKS with no built-in CNI, AKS Flex Node, upstream Cilium, managed Istio Gateway API, ACR, Storage, Managed Identity, Log Analytics |
| Anyscale | Anyscale on Azure Platform cloud, AKS marketplace extension, Anyscale CLI, Ray Jobs |
| Workload | Python, Ray Train, DeepSpeed, PyTorch, Azure Blob result storage through workload identity |
| Validation | Bash gates, `jq`, `kubectl`, Azure CLI, Terraform validate, TypeScript, markdownlint, ruff, mypy, npm audit |

## Lab Flow

The student path is module-based, and the E2E harness maps directly to those modules:

| Module | E2E phase | Main scripts |
| --- | --- | --- |
| 1-2 Environment + AKS foundation | `foundation` | `scripts/anyscale-aks.sh doctor`, `scripts/anyscale-aks.sh apply`, `scripts/validate-lab-gates.sh m2` |
| 3 Flex Node | `flex` | `scripts/anyscale-aks.sh flex-config`, `scripts/anyscale-aks.sh flex-bootstrap`, `scripts/validate-lab-gates.sh m3` |
| 4 Anyscale binding | `anyscale` | Terraform `anyscale.tf`, AKS extension, `scripts/validate-lab-gates.sh m4` |
| 5 Preflight | `autoscale` | `scripts/install-nvidia-device-plugin.sh`, `scripts/validate-lab-gates.sh m5` |
| 6 Workload results | `results` | `scripts/run-anyscale-workload.sh --mode both` |
| 7 Teardown | `teardown` | `scripts/anyscale-aks.sh destroy`, `scripts/validate-lab-gates.sh teardown` |

Use `scripts/run-lab-e2e.sh all` for a full live run. The runner executes the CPU
workload unless the environment explicitly enables GPU. Use individual phases when
resuming after a targeted fix.

## Environment Files

Create a local `.env` from `.env-template` before you deploy. The template uses
shell-compatible `KEY="value"` lines. Keep the quotes and keep JSON values on one
line so the setup helper can read them.

```bash
cp .env-template .env
```

The template comments explain each setting next to the value. Start with the
settings you own rather than changing every default.

| Set or review | What you set | Why it matters |
| --- | --- | --- |
| Azure IDs | `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `TF_VAR_azure_subscription_id`, and `TF_VAR_azure_tenant_id` | Azure CLI and Terraform need to use the same subscription and tenant. |
| Ownership tag | `Owner` inside `TF_VAR_tags` | Tags make it clear who can answer questions about cost or cleanup. |
| SSH key path | `SSH_PRIVATE_KEY_PATH` | Module 3 uses the private key and its matching `.pub` file to reach the Flex VM. |
| Region pair | `TF_VAR_azure_location`, `TF_VAR_flex_region`, and both `*_region_short` values | AKS runs in the home region and the Flex VM runs in the second region. Both need quota and extension support. |
| Network ranges | VNet, Flex VNet, pod, and service CIDRs | These ranges must not overlap with networks you need to reach through your laptop, VPN, or Azure environment. |

`ARM_USE_CLI="true"` uses your existing Azure CLI sign-in. Do not put Azure passwords,
client secrets, private-key contents, Anyscale tokens, or kubeconfigs in `.env`.

The setup helper renders `TF_VAR_*` values into
`infra/terraform/terraform.auto.tfvars.json`. Both `.env` and rendered Terraform
state and plan files are ignored and must not be committed.

### Configure by lab stage

The starting values run the CPU path. Choose CPU or GPU settings from the quota
and capacity available in the target Azure environment. Leave later-stage
features disabled until the rendered module asks you to enable them.

| When | Setting | Recommended action |
| --- | --- | --- |
| Before Module 2 | `TF_VAR_flex_host_enabled` | Leave it `false`. The Flex VM does not exist yet. |
| Module 3 | `TF_VAR_flex_host_enabled` | Set it to `true` to create the customer-managed Flex VM. It starts Azure compute charges. |
| Module 4 | `TF_VAR_anyscale_enabled` | Set it to `true` after the extension availability preflight. This creates the Anyscale cloud, installs the operator, and creates a public Gateway IP. |
| CPU workload | `TF_VAR_gpu_pool_configs` and `ANYSCALE_FLEX_GPU_ENABLED` | Leave them disabled for a CPU environment. |
| GPU workload | Flex VM size, Flex image, `ANYSCALE_FLEX_GPU_ENABLED`, and `ANYSCALE_RESULTS_GPU_*` | Change these as one group after you confirm GPU quota and follow the GPU module. |

Keep `TF_VAR_assign_current_principal_cluster_access="true"` for a self-guided lab.
It gives the Azure user who runs Terraform the AKS access needed by the scripts. Only
turn it off when your platform team manages equivalent access through the principal
maps at the end of `.env`.

`TF_VAR_anyscale_platform_default_admin_assignment` is also enabled by default.
It gives the deploying Azure user the Anyscale Platform Administrator role at
subscription scope. Keep it enabled unless an administrator has already granted you
an equivalent role.

### Check your configuration

Render the Terraform variables before a plan. This catches malformed JSON and missing
values without creating Azure resources:

```bash
./scripts/anyscale-aks.sh render-tfvars
terraform -chdir=infra/terraform validate
```

You can keep a separate local profile for another subscription or environment without
editing `.env`:

```bash
ANYSCALE_AKS_ENV_FILE=.env-lab2 ./scripts/anyscale-aks.sh plan
```

Format `.env-lab2` the same way as `.env-template` and keep it out of Git.

Important GPU settings:

```bash
TF_VAR_flex_host_vm_size="<gpu-vm-size>"
TF_VAR_flex_host_source_image_reference='<gpu-ready-source-image-reference-json>'
ANYSCALE_FLEX_GPU_ENABLED="true"
ANYSCALE_RESULTS_GPU_ACCELERATOR_TYPE="<anyscale-accelerator-type>"
ANYSCALE_RESULTS_GPU_PRODUCT_LABEL="<kubernetes-gpu-product-label>"
ANYSCALE_RESULTS_GPU_TARGET="flex"
ANYSCALE_RESULTS_GPU_WORKER_COUNT="1"
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
bash -n scripts/run-anyscale-workload.sh
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
./scripts/run-lab-e2e.sh results
./scripts/run-lab-e2e.sh teardown
```

Workload results are written under `.cache/anyscale/results/`. Check summaries directly:

```bash
python3 workloads/deepspeed_finetune/validate_workload_summary.py \
  .cache/anyscale/results/<job-name>-workload-summary.json
```

Placement comes from `<job-name>-kubernetes-placement.json`. For GPU success, the worker pod must be on `agentpool=aksflexnodes` in the Flex region and the workload summary must report `cuda_available=true` with a `device_name` that matches the selected accelerator.

The runner writes phase timing and status to
`.github/agents/state/e2e-run-journal.md`. Use that journal as the human-readable
run record and keep the adjacent JSON files for automated checks.

## Troubleshooting Patterns

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Module 4 operator crash says gateway address missing | Extension rendered gateway config without an address | Configure both `networking.gateway.hostname` and `networking.gateway.ip` |
| Module 4 RBAC gate fails | Current Azure principal lacks Anyscale Platform role | Keep `TF_VAR_anyscale_platform_default_admin_assignment` enabled or pre-create equivalent role assignment |
| Module 5 GPU gate has no allocatable GPU | NVIDIA device plugin not ready or Flex host lacks driver | Use the GPU host image, run `scripts/install-nvidia-device-plugin.sh`, and wait for allocatable `nvidia.com/gpu` |
| GPU worker Pending with an unmatched `nvidia.com/gpu.product` selector | Flex node lacks the configured product label | Correct `ANYSCALE_RESULTS_GPU_PRODUCT_LABEL` and re-run `scripts/install-nvidia-device-plugin.sh` |
| Anyscale console shows Jobs but no Workspaces | The lab uses Anyscale Jobs, not Workspaces | Expected behavior |
| Old Azure Anyscale cloud remains in Anyscale console after Azure cleanup | Stale control-plane registration with no backing ARM resource | Provider-side cleanup is required; `anyscale cloud delete` is unsupported for Azure clouds |

## Cleanup

Always run teardown after live tests:

```bash
./scripts/run-lab-e2e.sh teardown
terraform -chdir=infra/terraform state list
```

A successful teardown prints `PASS M7-01 resource group deleted` and `PASS M7-02 terraform state empty`.
