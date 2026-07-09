# AKS Flex Node + Anyscale Multi-Region Workload Lab

This repository contains a hands-on lab and supporting infrastructure for learning how to:

- deploy a public AKS foundation,
- extend cluster capacity across regions with AKS Flex Node,
- prepare an Anyscale-on-AKS integration path,
- validate quota-aware CPU scaling behavior, and
- capture machine-readable evidence for placement, elasticity, and saturation.

## Workshop Scenario

The workshop demonstrates:

- home region AKS cluster in `westus2`,
- Flex host expansion in `westus3`,
- a CPU-only Anyscale proof across the AKS and Flex nodes, and
- a representative `deepspeed_finetune` proof workload with managed-identity storage evidence.

## Repository layout

- `docs/`: Docusaurus-style workshop content and assets.
- `infra/terraform/`: deployable AKS, networking, observability, storage, and Flex host infrastructure.
- `scripts/`: operator entrypoints, lint commands, and workload helpers.
- `workloads/`: workload proof packages and validation helpers.

## Development setup

Install the local tools and dependencies before running the lab or validation checks.

### Prerequisites

- Node.js 22 or higher
- npm
- Terraform 1.9+
- Azure CLI
- `pre-commit`, `ruff`, `mypy`, `shellcheck`, `shfmt`, and `markdownlint-cli2`

### Install docs dependencies

```bash
npm install
```

### Run the docs site locally

```bash
scripts/docs-dev.sh
```

Validate the production docs build before committing:

```bash
npm run build
```

### Run repository validation

```bash
scripts/lint.sh
```

## Related files

- workshop entrypoint: `docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx`
- live deploy helper: `scripts/anyscale-aks.sh`

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.
