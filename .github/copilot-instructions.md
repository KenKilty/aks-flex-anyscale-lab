# Copilot Instructions

## Lab Writing Style Comes First

When editing Markdown or MDX in this repository, load and follow `.github/skills/lab-writing-style/SKILL.md` before drafting or revising text.

This applies to README text, Docusaurus module pages, shared Markdown components, workload README files, troubleshooting notes, and developer docs.

Use the skill to keep lab prose student-friendly, concrete, evidence-led, and free of promotional or AI-pattern filler. Keep exact commands, expected output, resource names, and API names technically precise.

Before finishing doc work, check that the edited text explains why the step matters, what the student should see, and what command or artifact proves it.

For student-facing text-only edits, apply the `Student Text Acceptance Criteria`
in `.github/skills/lab-writing-style/SKILL.md`. Preserve validated commands,
Terraform values, resource labels, timeouts, and deployment order unless the
request explicitly requires a functional change. Keep shared prerequisites in
Module 1 only, make CPU and GPU applicability explicit, and validate with
Markdown lint and a production build when available.

## Authoritative sources

The rendered student modules in `docs/ai-workloads-on-aks/` define the lab. The
Developer Guide in `docs/DEVELOPER.md` defines how to maintain and extend it.
When code and a student page disagree, treat the disagreement as a defect and fix
both in the same change.

## Lab testing policy

End-to-end testing goes through the rendered student lab only. Use the prompt in
`.github/prompts/browser-led-student-lab.prompt.md`.

- Do not create a script, harness, phase runner, or helper that deploys the lab
  end to end. This repository deliberately has no such entrypoint. A harness
  proves the scripts run; it cannot prove the instructions are followable, which
  is the failure students actually hit.
- Do not add a command, flag, or file that exists only for testing the lab and is
  not part of a student module or the Developer Guide.
- Every student-executed command must appear on a module page. If a command is
  needed to complete the lab but is not documented, document it rather than
  adding a helper.
- Offline unit tests of shell logic are allowed and run through `scripts/lint.sh`.
  They must not deploy Azure or Anyscale resources.
- When changing a script that a module invokes, update that module page in the
  same change, including expected output.

## Docs development workflow

Always use `scripts/docs-dev.sh` to start or restart the local Docusaurus dev server.
This script kills any stale process on port 3000, clears the Docusaurus cache (`docusaurus clear`), and starts fresh so stale builds do not trigger `@generated` module errors.

```bash
scripts/docs-dev.sh
```

Never suggest `npm start` directly for local docs development.
Use `npm run build` to validate the production build before committing.

## Repository structure

- `docs/`: Docusaurus workshop content. All new workshop pages go in `docs/ai-workloads-on-aks/`.
- `infra/terraform/`: AKS, networking, storage, and Flex host infrastructure.
- `scripts/`: Operator entrypoints, lint commands, workload helpers, and docs helpers.
- `workloads/`: Workload proof packages and validation helpers.
- `src/`: Docusaurus React components and CSS.

## Code style and quality

Run `scripts/lint.sh` before committing. It covers:

- Python (ruff format + ruff check)
- Shell (shellcheck)
- Markdown and MDX (markdownlint-cli2)
- TypeScript (tsc --noEmit)
- npm security audit (scripts/audit-npm.sh)
- Terraform (fmt + validate)

## Deployment

- Use `.env-template` as the base for local `.env` files.
- Use `ANYSCALE_AKS_ENV_FILE=<file> ./scripts/anyscale-aks.sh <command>` for alternate profiles.
- Never commit `.env` files.

## Anyscale on Azure

This repository targets Anyscale on Azure. It does not support generic Anyscale
Marketplace onboarding, `anyscale cloud setup`, `anyscale cloud register`, or a
direct Helm installation of the Anyscale operator.

Set the Azure control-plane host for every Anyscale CLI command, including skill
installation and updates:

```bash
ANYSCALE_HOST=https://console.azure.anyscale.com \
  .venv/bin/anyscale <command>
```

Do not use `https://console.anyscale.com`, add another Anyscale control-plane
option, or accept a caller-provided host for lab workflows. Never request an
Anyscale token in chat. Use the CLI credential store populated by
`.venv/bin/anyscale login` against the Azure host.

Never rely on the organization default cloud. Resolve exactly one cloud by its
full Azure ARM resource path before a cloud-bound operation, and fail if the
record is missing, duplicated, or unhealthy. Pass that full name with `--cloud`
for Job, Service, and Workspace operations and with `--cloud-name` for supported
compute-config operations. Every compute-config YAML must include the full ARM
cloud name. Operations on an existing resource may use its immutable `--id`.
Read-only cloud discovery (`cloud list` and `cloud get-default`) is exempt because
it does not select a workload target. Do not change the organization default as
part of a lab deployment or teardown. `scripts/check_anyscale_cloud_scope.py`
enforces these requirements for shell entrypoints during `scripts/lint.sh`.

The repository's Terraform, `.env` variables, wrapper scripts, and validation
gates define the deployment contract. They take precedence over generic commands,
fixed hardware examples, and deployment methods in an official Anyscale skill.
Derive VM sizes, accelerator types, Kubernetes GPU product labels, and worker
counts from `.env` and Terraform. Do not introduce a fixed CPU or GPU SKU.

Create the Anyscale cloud through the `Anyscale.Platform` Azure resource
provider. Terraform must own the parent `Anyscale.Platform/clouds` resource and
its `cloudResources/default` child as first-class `azapi_resource` objects. Bind
the child's `cloudResourceId` to the Anyscale AKS operator extension and preserve
the dependency chain from the Gateway to the extension, child, parent, AKS,
identity, and storage. Do not move deletion of those Azure resources into shell
scripts; imperative teardown is limited to Anyscale control-plane preconditions
that Terraform cannot observe, such as active workloads and system-cluster state.
The extension's Marketplace `plan` block is part of this RP-bound Anyscale on
Azure deployment and matches the official Terraform example; it is not the
unsupported standalone Marketplace onboarding path. Do not deploy the operator
extension without the `Anyscale.Platform` cloud resources, and do not install the
operator as a Helm release. Student-facing text should describe the Anyscale on
Azure resource and its Azure-managed AKS operator rather than presenting a
separate Marketplace deployment choice.

### Anyscale skill routing

- Use `anyscale-platform-ask` first for current Ray or Anyscale behavior,
  architecture, API, and documentation questions. Ground answers in current
  Anyscale on Azure documentation and repository code.
- Use `anyscale-infra-kubernetes` for AKS operator, Kubernetes networking,
  workload identity, storage, and troubleshooting context. Ignore its generic
  `cloud setup`, `cloud register`, and Helm deployment paths for this repository;
  those paths target the standard Anyscale control plane rather than Anyscale on
  Azure.
- Use `anyscale-platform-inspect` for read-only validation of local workload
  files or live Anyscale jobs, workspaces, services, logs, events, and metrics.
- Use `anyscale-workload-llm-post-training` for the synthetic GPT-2-style Ray
  Train and DeepSpeed fine-tuning workload in `workloads/deepspeed_finetune/`.
- Use `anyscale-workload-ray-train` only for lower-level `TorchTrainer`,
  `ScalingConfig`, checkpoint, and Ray Train runtime questions not covered by
  the LLM post-training skill.
- Use `anyscale-platform-fix` only when the user asks to modify or repair a
  failing workload. Keep fixes within the repository's existing workload and
  submission abstractions.
- Use `anyscale-platform-run` only when the user explicitly asks to create,
  submit, deploy, terminate, or otherwise mutate an Anyscale resource. Prefer
  the repository entrypoints in `scripts/` over generated parallel configs.
- Do not use the AWS VM, GCP VM, serving, Ray Data, batch embedding, or physical
  AI skills unless the repository gains a corresponding workload.

Read-only Anyscale research and inspection may proceed without deployment
confirmation. Before a skill creates or changes a billable Anyscale resource,
state the intended operation and use the Azure control-plane host above.

### Doctor command

When changing `./scripts/anyscale-aks.sh doctor`, use `anyscale-platform-ask` and
`anyscale-infra-kubernetes` for current prerequisite context, then implement the
checks in the repository scripts. The doctor command should fail early for an
incorrect Anyscale host, missing or unauthenticated Anyscale CLI, mismatched Azure
subscription or tenant, unregistered Azure resource providers, unsupported
Anyscale on Azure region, invalid `.env` values, unavailable VM quota or SKU, and
missing local tools. Keep checks read-only, print concrete PASS or remediation
output, and never print credentials.

<!-- mermaid-ai-skills:start -->
## Mermaid Diagrams

When the user asks to create, edit, or visualize a diagram, follow the
instructions in `.github/instructions/mermaid.instructions.md`.
<!-- mermaid-ai-skills:end -->
