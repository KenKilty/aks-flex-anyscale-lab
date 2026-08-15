---
title: Developer Guide
description: Develop, validate, and test the AKS Flex Node and Anyscale lab.
sidebar_position: 99
sidebar_label: Developer Guide
tags:
  - contributing
  - developer
---

This guide explains the repository structure, documentation conventions, local
tooling, and checks to run before a live Azure end-to-end test. Read the
repository-root `CONTRIBUTING.md` first for the workshop scope and submission
expectations.

## Repository map

| Path | Purpose |
| --- | --- |
| `docs/ai-workloads-on-aks/` | Student workshop modules, Key Concepts, and diagram assets |
| `docs/DEVELOPER.md` | This guide, published as the last sidebar entry |
| `infra/terraform/` | Root configuration: `main.tf`, `anyscale.tf`, `unbounded.tf`, `managed-network.tf`, `variables.tf`, `outputs.tf`, `versions.tf` |
| `infra/terraform/modules/` | `acr`, `aks`, `aks_public`, `dns`, `flex_host`, `identity`, `network`, `observability`, `storage` |
| `infra/terraform/templates/` | ARM template body for the `Anyscale.Platform` cloud resource |
| `infra/terraform/tests/` | `plan.tftest.hcl` plan-time assertions run by `terraform test` |
| `scripts/` | Operator entrypoints, module gates, workload helpers, and lint |
| `scripts/lib/` | Shared Bash libraries: job submission, Flex network gates, timeout helpers |
| `workloads/deepspeed_finetune/` | Ray Train and DeepSpeed workload, summary schema, and validator |
| `src/` | Docusaurus React and CSS customizations, including `SharedMarkdown` partials |
| `sidebars.ts` and `docusaurus.config.ts` | Manual sidebar order and site configuration |
| `.github/copilot-instructions.md` | Repository rules that agents must follow |
| `.github/skills/lab-writing-style/` | Prose rules and student acceptance criteria |
| `.github/prompts/` | The browser-led student lab UX test prompt |
| `.env-template` | Committed deployment variable contract; copy to ignored `.env` |
| `requirements-tooling.txt` | Pinned Anyscale CLI used by bootstrap and workload scripts |
| `.pre-commit-config.yaml` | Hook definitions that `scripts/run-pre-commit.sh` runs on demand |

These paths are ignored and must never be committed: `.env`, `.cache/`,
`.vscode/`, `LABTEST.md`, `.github/browser-led-student-lab-findings.md`, and
Terraform state and plan files.

## How the lab works

Read this before changing infrastructure, scripts, or module order. The lab is a
single dependency chain, and most defects come from breaking one of its links.

1. **Configuration.** You edit `.env`. Every Terraform command first runs
   `render_tfvars`, which writes the current `TF_VAR_*` values to
   `infra/terraform/terraform.auto.tfvars.json`. Terraform never reads `.env`
   directly, so a value that does not reach the rendered file does not reach
   Terraform.
2. **Azure foundation (Module 2).** One apply creates the resource group, two
   VNets with peering in both directions, a public AKS cluster with the `sys`
   and `cpu` pools, an optional GPU pool, ACR, a storage account, Log Analytics,
   managed identities, and the Flex VM. Terraform creates the peering before the
   Flex VM so the VM has its network path on first boot.
3. **Pod networking.** AKS runs with `networkPlugin=none`, so it installs no CNI.
   `unbounded.tf` installs Unbounded, which owns pod networking for the managed
   nodes using `TF_VAR_aks_pod_cidr` and, after the Flex node joins, for Flex
   using `TF_VAR_unbounded_flex_pod_cidr`. Unbounded runs kube-proxy on Flex
   only and links the two sites across the peered VNets.
4. **Flex join (Module 3).** `flex-config` resolves the current stable AKS Flex
   Node release, downloads the matching tool, and creates a bootstrap token.
   `flex-bootstrap` copies that config to the VM, verifies the archive checksum
   against the same release, starts the service, applies the pool and region
   labels plus the `aks-flex-node` taint, and approves the node's certificate
   requests. The Module 3 gate requires those labels and the taint, so a Ready
   node alone does not pass.
5. **Anyscale binding (Module 4).** Terraform owns the
   `Anyscale.Platform/clouds` parent and its `cloudResources/default` child as
   first-class `azapi_resource` objects. The child's `cloudResourceId` binds to
   the AKS operator extension. Managed Istio provides the Gateway API, and the
   Gateway publishes a Terraform-managed public IP.
6. **Workload (Module 6).** `run-anyscale-workload.sh` reads allocatable CPU and
   memory from the Ready nodes for each role, reserves headroom, caps each
   request at the smoke target, writes a compute config under
   `.cache/anyscale/compute-configs/`, and submits an Anyscale Job. It then saves
   the workload summary and Kubernetes placement under `.cache/anyscale/results/`.
7. **Teardown (Module 7).** `destroy` first drains Anyscale Jobs, asserts no
   active Services or Workspaces, terminates the system cluster, and archives the
   lab compute configs. Only then does Terraform delete Azure resources in
   dependency order: Gateway, extension, Anyscale child and parent, Flex host,
   then the remaining infrastructure.

Invariants worth protecting when you change code:

- Terraform owns the Anyscale resource-provider objects. Do not move their
  deletion into shell scripts. Imperative teardown is limited to control-plane
  preconditions Terraform cannot observe.
- Every Anyscale CLI call uses `https://console.azure.anyscale.com` and resolves
  exactly one cloud by its full ARM name. `scripts/check_anyscale_cloud_scope.py`
  enforces this during `scripts/lint.sh`.
- Do not introduce a fixed CPU or GPU SKU. Sizes come from `.env` and live node
  capacity.

## Command surface

Several entrypoints are thin wrappers. Edit the implementation, not the alias.

| You run | Implemented by | Notes |
| --- | --- | --- |
| `scripts/anyscale-aks.sh <command>` | `scripts/setup.sh` | The wrapper validates the subcommand, then execs `setup.sh` |
| `scripts/run-anyscale-workload.sh` | `scripts/run-anyscale-results.sh` | Sizing, submission, and evidence collection live in the results script |

`scripts/validate-lab.sh` is the gate runner itself, not a wrapper. Flex
networking checks come from `scripts/lib/flex-network-gates.sh`, which both the
validator and the workload script source.

`scripts/anyscale-aks.sh` accepts `bootstrap`, `sku-options`, `doctor`, `status`,
`render-tfvars`, `init`, `validate`, `test`, `plan`, `apply`, `destroy`,
`output`, `flex-config`, and `flex-bootstrap`.

`scripts/validate-lab.sh` accepts `m2`, `m3`, `m4`, `m5`, `m6-local`,
`preflight`, and `teardown`. Students use a subset; `preflight` and `m6-local`
exist for development and the harness.

Set `ANYSCALE_AKS_ENV_FILE=<file>` on any of these to use an alternate profile
without editing `.env`.

## Technical stack

| Area | Tools |
| --- | --- |
| Documentation | Docusaurus 3, MDX, Mermaid, SVG assets |
| Infrastructure | Terraform, AzureRM provider, AzAPI provider |
| Azure services | AKS with `networkPlugin=none` and Unbounded networking, AKS Flex Node with Unbounded pod networking and kube-proxy, managed Istio Gateway API, ACR, Storage, Managed Identity, Log Analytics |
| Anyscale | Anyscale on Azure Platform cloud, AKS marketplace extension, Anyscale CLI, Ray Jobs |
| Workload | Python, Ray Train, DeepSpeed, PyTorch, Azure Blob result storage through workload identity |
| Validation | Bash checks, `jq`, `kubectl`, Azure CLI, Terraform tests, TypeScript, markdownlint, ruff, mypy, npm audit |

## Documentation authoring

Add workshop pages under `docs/ai-workloads-on-aks/` with lowercase,
hyphen-separated file names. Keep infrastructure, scripts, workload code, and
large configuration artifacts in their existing source directories instead of
duplicating them in a page.

Every page under `docs/` needs this frontmatter:

```yaml
---
title: "Module N: Imperative title"
description: State what the reader builds or verifies.
sidebar_position: 1
sidebar_label: "Module N: Short navigation title"
tags:
  - aks
---
```

Register a new, removed, or reordered module in `sidebars.ts`. The sidebar is
manually ordered so the dependency sequence cannot change through file-name
sorting alone.

Use the established module structure:

1. Open with the result the module produces and why the next module needs it.
2. Use `## What You Will Do` for scope.
3. Write numbered `## Step N:` headings with imperative verbs.
4. Put each verification beside the action it verifies and name the stable
   field, state, or saved artifact that indicates success.
5. End with optional `## Troubleshooting` for known failure modes, then
   `## Validate <result>`, then `## Next step`.

Import shared content instead of repeating it:

```javascript
import Prerequisites from "../../src/components/SharedMarkdown/_prerequisites.mdx";
import Cleanup from "../../src/components/SharedMarkdown/_cleanup.mdx";
```

`<Prerequisites />` owns the shared prerequisite list in Module 1. Later modules
may name a dependency but should not repeat that list. Use `<Cleanup />` only
where its short cleanup reminder complements, rather than replaces, the full
Module 7 teardown.

Store images and diagrams under
`docs/ai-workloads-on-aks/assets/<workshop-or-diagram-group>/`. Give every image
descriptive alt text. Use relative links for repository content and locale-neutral
Microsoft Learn URLs for external Azure documentation. Screenshots should use a
readable resolution and show only the UI needed for the instruction.

Commands, paths, variable names, labels, and expected result files must come
from the scripts, Terraform, or a validated run. Keep command and output fences
separate, label every fence, and replace generated IDs, IP addresses, versions,
and timestamps with named placeholders. Reserve warnings and cautions for cost,
security, destructive actions, or conditions that prevent the next step.

For the complete prose rules and student acceptance criteria, read
`.github/skills/lab-writing-style/SKILL.md`.

## Lab flow

The student modules are the authoritative definition of the lab. Each module maps
to the commands below, and there is no separate harness that runs them:

| Module | Student commands |
| --- | --- |
| 1 Environment | `scripts/anyscale-aks.sh bootstrap`, `sku-options`, `doctor` |
| 2 AKS foundation | `scripts/anyscale-aks.sh plan`, `apply` |
| 3 Flex Node | `scripts/anyscale-aks.sh flex-config`, `flex-bootstrap`, `scripts/validate-lab.sh m3` |
| 4 Anyscale binding | `scripts/anyscale-aks.sh apply` with Anyscale enabled, `scripts/validate-lab.sh m4` |
| 5 Readiness | `scripts/install-nvidia-device-plugin.sh` for GPU, `scripts/validate-lab.sh m5` |
| 6 Workload results | `scripts/run-workload-smoke.sh`, `scripts/run-anyscale-workload.sh --mode cpu\|gpu` |
| 7 Teardown | `scripts/anyscale-aks.sh destroy`, `scripts/validate-lab.sh teardown` |

If you change any of these commands, change the owning module page in the same
edit. A command that exists only in this guide is not part of the lab.

## Environment files

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
| Azure IDs | `TF_VAR_azure_subscription_id` and `TF_VAR_azure_tenant_id` | Bootstrap copies the active Azure CLI subscription and tenant into the profile. |
| Ownership tag | `Owner` inside `TF_VAR_tags` | Tags make it clear who can answer questions about cost or cleanup. |
| SSH key path | `SSH_PRIVATE_KEY_PATH` | Module 3 uses the private key and its matching `.pub` file to reach the Flex VM. |
| Region pair | Both location and `*_region_short` values | AKS runs in the home region and the Flex VM runs in the second region. Use concise labels such as `wus2` for `westus2`; the labels become part of resource names. |
| Network ranges | VNet, Flex VNet, pod, and service CIDRs | These ranges must not overlap with networks you need to reach through your laptop, VPN, or Azure environment. |

The setup helper exports Terraform's `ARM_SUBSCRIPTION_ID` and `ARM_TENANT_ID`
from the corresponding `TF_VAR_azure_*` values at runtime. Do not put Azure
passwords, client secrets, private-key contents, Anyscale tokens, or kubeconfigs
in `.env`.

The setup helper renders `TF_VAR_*` values into
`infra/terraform/terraform.auto.tfvars.json`. Both `.env` and rendered Terraform
state and plan files are ignored and must not be committed.

### Configure by lab stage

The starting values run the CPU path. Before changing regions or worker SKUs,
run `./scripts/anyscale-aks.sh sku-options REGION_A REGION_B cpu|gpu`. The
command lists unrestricted SKUs with quota for one VM in each region. Save one
shared worker SKU as both `TF_VAR_cpu_vm_size` and
`TF_VAR_flex_host_vm_size` for CPU mode, or as the managed GPU pool SKU and
`TF_VAR_flex_host_vm_size` for GPU mode. The Flex VM is enabled because every
path uses it. Anyscale remains disabled until Module 4 confirms that the AKS
cluster can install the operator extension.

| When | Setting | Recommended action |
| --- | --- | --- |
| Before Module 2 | `TF_VAR_flex_host_enabled` | Keep the default `true`. Module 2 creates the customer-managed Flex VM and starts its Azure compute charges. |
| Module 4 | `TF_VAR_anyscale_enabled` | Set it to `true` after the extension availability check. This creates the Anyscale cloud, installs the operator, and creates a public Gateway IP. |
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
TF_VAR_gpu_pool_configs='{"gpu":{"name":"gpupool","vm_size":"<shared-gpu-vm-sku>","product_name":"<gpu-product-label>","gpu_count":"1","min_count":1,"max_count":1,"availability_zones":[]}}'
TF_VAR_flex_host_vm_size="<shared-gpu-vm-sku>"
TF_VAR_flex_host_source_image_reference='<gpu-ready-source-image-reference-json>'
ANYSCALE_FLEX_GPU_ENABLED="true"
ANYSCALE_RESULTS_GPU_PRODUCT_LABEL="<gpu-product-label>"
```

Keep each node domain at one GPU. The GPU workload starts two Ray Train workers
and fails unless one trains on the managed pool and one trains on Flex.

Important Anyscale user RBAC setting:

```bash
TF_VAR_anyscale_platform_default_admin_assignment='{"enabled":true,"principal_type":"User","role_definition_name":"Anyscale Platform Administrator","scope":"subscription"}'
```

## Local documentation development

Use Node.js 22 or later. Install the versions recorded in `package-lock.json`:

```bash
npm ci
```

Start the Docusaurus dev server using the repository helper:

```bash
scripts/docs-dev.sh
```

The helper clears the Docusaurus cache, stops any stale process on the selected
port, and starts the site without opening an external browser. Use it instead of
calling `npm start` directly. To use another port:

```bash
DOCS_PORT=3001 scripts/docs-dev.sh
```

Validate the production build:

```bash
npm run build
```

## Validation commands

Run fast focused checks while editing:

```bash
bash -n scripts/validate-lab.sh
bash -n scripts/run-anyscale-results.sh
shellcheck scripts/*.sh
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform validate
terraform -chdir=infra/terraform test
npx markdownlint-cli2 README.md CONTRIBUTING.md 'docs/**/*.{md,mdx}'
npm run typecheck
```

Run the repository checks before committing:

```bash
scripts/lint.sh
npm run build
```

`scripts/lint.sh` covers Python formatting and checks, ShellCheck and shell
formatting, Markdown and MDX, TypeScript, npm audit, and Terraform formatting and
validation. Some steps format files in place, so inspect the resulting diff. The
npm audit check can pass with reviewed exceptions listed in
`scripts/audit-npm.sh`; add an exception only after reviewing the advisory and
recording why the remaining risk is acceptable.

## End-to-end testing

The rendered student modules are the only end-to-end test path. This repository
has no script harness that deploys the lab, and it should not gain one. A harness
exercises the scripts; it cannot prove that the instructions a student reads are
correct, complete, and in a workable order. Those defects are the ones that reach
students.

Run a full test with the prompt at
`.github/prompts/browser-led-student-lab.prompt.md`. Invoke it in VS Code chat
and pass optional arguments to narrow scope, such as a CPU-only run or a
suspected regression.

Before starting, confirm the baseline is clean:

```bash
terraform -chdir=infra/terraform state list
source .env
az group exists --subscription "$TF_VAR_azure_subscription_id" --name "rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
```

Expected clean baseline:

```text
false
```

What the prompt does, and why each rule matters:

- It enters student mode after two read-only credential preflights, then treats
  the rendered pages as the only runbook. It must not read scripts, Terraform, or
  Markdown source to make progress, so a missing or wrong instruction fails the
  run instead of being silently worked around.
- It runs every command from a fresh clone in a temporary directory, so a file
  that only exists in your working copy cannot mask a gap.
- It leaves student mode only after an observed error or a contradiction between
  the page and the result. The remediation loop then fixes the root cause and the
  affected page together, revalidates, and returns to student mode.
- It chronicles each step in `LABTEST.md` with the rendered instruction, exact
  command, observed result, evidence, and status. Failures stay in the record.
- It must follow the rendered teardown even after a workload failure, and must
  not report success while any billable resource is unverified.

Run it before a release, after changing module order or command text, and
whenever a student reports that an instruction did not work.

`LABTEST.md` and `.github/browser-led-student-lab-findings.md` are ignored. Treat
them as run output: harvest fixes into source changes, then let the next run
replace them.

### Inspect workload evidence

Workload results are written under `.cache/anyscale/results/`. Check summaries
directly:

```bash
python3 workloads/deepspeed_finetune/validate_workload_summary.py \
  .cache/anyscale/results/<job-name>-workload-summary.json
```

Placement comes from `<job-name>-kubernetes-placement.json`. For GPU success, the
worker pod must be on `agentpool=aksflexnodes` in the Flex region and the workload
summary must report `cuda_available=true` with a `device_name` that matches the
selected accelerator.

### Focused checks during development

Unit tests for shell logic still run offline through `scripts/lint.sh`:
`test-doctor-vm-quota.sh`, `test-sku-options.sh`, and
`test-run-anyscale-results.sh`. They cover quota aggregation, cross-region SKU
selection, and workload sizing. They deploy nothing and are not a substitute for
the student run. Use them to catch a regression before you spend a live test.

## Editor and MCP tooling

MCP servers are optional, but they shorten live debugging. Configure them in
`.vscode/mcp.json`, which is ignored so your subscription and cluster IDs stay
local.

| Server | Use it for | Notes |
| --- | --- | --- |
| `aks-mcp` | Live AKS inspection: `az` queries, monitoring, network and compute detail, AKS detectors, Advisor, `kubectl`, and Helm | Run it with `--access-level readonly` for lab work |
| Pylance MCP | Python analysis for `workloads/deepspeed_finetune/` | Provided by the Pylance extension; no repository configuration |

A working `aks-mcp` entry looks like this. Replace the resource ID with your own
cluster and keep the file out of Git:

```json
{
  "servers": {
    "aks-mcp-lab": {
      "type": "stdio",
      "command": ".cache/aks-mcp/<version>/aks-mcp",
      "args": [
        "--transport", "stdio",
        "--access-level", "readonly",
        "--default-aks-resource-id", "<aks-resource-id>",
        "--enabled-components", "az_cli,monitor,network,compute,detectors,advisor,kubectl,helm"
      ]
    }
  }
}
```

Agent behavior in this repository is also shaped by `.github/copilot-instructions.md`,
the `.github/skills/lab-writing-style/SKILL.md` prose rules, and the Anyscale
skills named in those instructions. Update the instructions file when you change
a deployment contract that an agent could otherwise violate.

## Extending the lab

### Add or reorder a module

1. Create the page in `docs/ai-workloads-on-aks/` with complete frontmatter.
2. Register it in `sidebars.ts`; ordering is manual on purpose.
3. Update the module tables in `README.md` and the workshop overview page.
4. Update the `Lab flow` table above with the module's student commands.
5. Fix the `## Next step` link on the preceding module.

### Add a validation gate

Add the check to `scripts/validate-lab.sh` under the matching phase and
reuse `scripts/lib/flex-network-gates.sh` for Flex networking. Give each check a
stable `M<module>-<number>` identifier, because the student pages and this guide
quote those strings as expected output. Print a concrete remediation on failure
and keep checks read-only.

### Add or change an environment setting

Add the key to `.env-template` with an explanatory comment, thread it into
`render_tfvars` in `scripts/setup.sh`, declare it in
`infra/terraform/variables.tf`, and document it in the Module 1 settings table.
A `TF_VAR_*` value that is not rendered never reaches Terraform.

### Add a Terraform module

Place it under `infra/terraform/modules/<name>/`, call it from the root
configuration, and add plan-time assertions to `infra/terraform/tests/`. Preserve
the dependency chain into the Anyscale resources; the Gateway, extension,
cloud child, and cloud parent must still be destroyable in order.

### Change the workload

Edit `workloads/deepspeed_finetune/train.py`, then update
`workload-summary-schema.json` and `validate_workload_summary.py` together. Any
new field that the student inspects must appear in the schema, the validator,
and the Module 6 expected output. Keep `--local-smoke` working on macOS, where
the local path uses native PyTorch instead of compiling the DeepSpeed extension.

## Maintenance

Review these pins on a regular cadence and after any upstream release that the
lab depends on:

| Item | Location | Notes |
| --- | --- | --- |
| Anyscale CLI | `requirements-tooling.txt` | Currently pinned exactly |
| Terraform and providers | `infra/terraform/versions.tf` | Terraform 1.9 or later, `azurerm ~> 4.72`, `azapi ~> 2.9` |
| Node and Docusaurus | `package.json` and `package-lock.json` | Node 22 or later; install with `npm ci` |
| AKS Flex Node release | Resolved at run time by `flex-config` | The lab tracks the current stable release rather than a pin |
| Anyscale operator extension | `infra/terraform/anyscale.tf` | Selected by release train; `version` stays null so the train chooses |
| npm audit exceptions | `scripts/audit-npm.sh` | Add an exception only with a recorded reason |
| Pre-commit hooks | `.pre-commit-config.yaml` | Run all hooks on demand with `scripts/run-pre-commit.sh` |

Recurring maintenance tasks:

- Re-verify external links in the student pages. They are the most common silent
  breakage, and Microsoft Learn URLs move.
- Refresh Module 6 console screenshots when the Anyscale UI changes.
- Re-run the browser-led prompt after upgrading the Anyscale CLI, the operator
  extension, or the AKS Kubernetes version.
- Confirm example output still matches reality when a tool changes its format.
  Quoted output in the pages is evidence and should come from a real run.

## Troubleshooting patterns

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Module 4 operator crash says gateway address missing | Extension rendered gateway config without an address | Configure both `networking.gateway.hostname` and `networking.gateway.ip` |
| Module 4 RBAC check fails | Current Azure principal lacks Anyscale Platform role | Keep `TF_VAR_anyscale_platform_default_admin_assignment` enabled or pre-create equivalent role assignment |
| Module 5 GPU check has no allocatable GPU | NVIDIA device plugin not ready or Flex host lacks driver | Use the GPU host image, run `scripts/install-nvidia-device-plugin.sh`, and wait for allocatable `nvidia.com/gpu` |
| GPU worker Pending with an unmatched `nvidia.com/gpu.product` selector | Flex node lacks the configured product label | Correct `ANYSCALE_RESULTS_GPU_PRODUCT_LABEL` and re-run `scripts/install-nvidia-device-plugin.sh` |
| Anyscale console shows Jobs but no Workspaces | The lab uses Anyscale Jobs, not Workspaces | Expected behavior |
| Old Azure Anyscale cloud remains in Anyscale console after Azure cleanup | Stale control-plane registration with no backing ARM resource | The Azure RP owns normal deletion; ask the provider to reconcile a shell whose ARM resource is already gone |

## Cleanup

Always run teardown after live tests:

```bash
./scripts/anyscale-aks.sh destroy
./scripts/validate-lab.sh teardown
terraform -chdir=infra/terraform state list
```

A successful teardown prints all three cleanup checks:

```text
PASS M7-01 resource group deleted
PASS M7-02 AKS managed resource group deleted
PASS M7-03 terraform state empty
```

An interrupted destroy is not a failure state to work around. Rerun the same
`./scripts/anyscale-aks.sh destroy` command; it reconciles from the preserved
Terraform state and is safe to repeat until it reports no objects to destroy.

## Pull request checklist

Before you open a pull request:

1. Keep the change focused and search existing issues or pull requests for the
  same problem.
2. Do not commit `.env`, credentials, kubeconfigs, private keys, Terraform state
  or plan files, generated `.cache/` evidence, or customer-specific values.
3. Preview changed documentation with `scripts/docs-dev.sh`. Check heading order,
  navigation, command wrapping, image alt text, and desktop and narrow layouts.
4. Run `scripts/lint.sh` and `npm run build`. Include any focused Terraform,
  script, or workload tests relevant to the change.
5. For a functional lab change, record the live phase or full E2E command you
  ran, the saved evidence you inspected, and the teardown result.
6. In the pull request description, summarize the reader-visible change, list
  validation commands and results, and call out changes to cost, permissions,
  deployment order, or cleanup behavior.
