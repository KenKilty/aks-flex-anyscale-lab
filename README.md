# AKS Labs Candidate: AKS Flex Node + Anyscale Multi-Region Workload Lab

This repository is being shaped to align with the workshop structure used by [Azure-Samples/aks-labs](https://github.com/Azure-Samples/aks-labs).

It contains a hands-on lab and supporting infrastructure for learning how to:

- deploy a public AKS foundation,
- extend cluster capacity across regions with AKS Flex Node,
- prepare an Anyscale-on-AKS integration path,
- validate quota-aware GPU scaling behavior, and
- capture machine-readable evidence for placement, elasticity, and saturation.

## Current focus

The workshop scenario is:

- home region AKS cluster in `westus3` as the intended final target,
- fallback validated deployment in `eastus2` for live bring-up when capacity blocks `westus3`,
- Flex host expansion in `westus2`, and
- a representative `deepspeed_finetune` proof workload.

## Repository layout

- `docs/`: Docusaurus-style workshop content and assets.
- `infra/terraform/`: deployable AKS, networking, observability, storage, and Flex host infrastructure.
- `scripts/`: operator entrypoints, lint commands, and workload helpers.
- `workloads/`: workload proof packages and validation helpers.

## Development setup

This repo now includes the same style of documentation scaffolding that `aks-labs` uses.

### Prerequisites

- Node.js 22 or higher
- npm
- Terraform 1.9+
- Azure CLI
- `pre-commit`, `ruff`, `shellcheck`, and `markdownlint-cli2`

### Install docs dependencies

```bash
npm install
```

### Run the docs site locally

```bash
npm start
```

### Run repository validation

```bash
scripts/lint.sh
```

## Submission intent

The goal is to make this workshop easy to upstream into `aks-labs` by matching:

- Docusaurus content structure,
- workshop naming and frontmatter conventions,
- self-contained lab guidance, and
- reusable asset organization under category-local `assets/` folders.

## Related files

- workshop entrypoint: `docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx`
- live deploy helper: `scripts/anyscale-aks.sh`

## Known issues

Issues encountered during lab development are tracked in dedicated public repositories:

- [AKS Flex Node CA Certificate Initialization Issue](https://github.com/KenKilty/aks-flex-node-issue-repro) — CA certificate file not auto-initialized during bootstrap with bootstrap-token auth. Reported to Azure AKS Flex Node engineering team.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.
