# AKS Flex Node + Anyscale Multi-Region Workload Lab

This lab shows how to extend one AKS cluster with AKS Flex Node capacity in another location, bind that cluster to Azure-native Anyscale, and prove that Ray workers run where the lab says they run. It supports a low-cost CPU path and a GPU path validated with a Flex-hosted Tesla T4 worker.

![Home region AKS cluster with Flex expansion](docs/ai-workloads-on-aks/assets/aks-flex-anyscale-multi-region/01-home-region-flex-expansion.svg)

## What The Lab Proves

- A public AKS cluster in a home region can use a Linux Flex host joined from another Azure region.
- Anyscale on AKS can submit Ray jobs against that single Kubernetes cluster without workload code changes.
- CPU and GPU proof workers can be forced onto `agentpool=aksflexnodes` and verified with Kubernetes placement evidence.
- The GPU proof uses a `GPU:1` Ray worker on a Flex T4 host, not an AKS managed GPU node pool.
- Anyscale workload identity writes and reads proof summaries from Azure Blob Storage without shared keys or SAS tokens.
- Teardown removes the current lab resource group and leaves Terraform state empty.

## Reference Topology

| Layer | Reference value | Purpose |
| --- | --- | --- |
| Home region | `westus2` | AKS, storage, ACR, observability, Anyscale cloud binding |
| CPU Flex region | `westus3` | Lower-cost cross-region Flex worker path |
| GPU Flex region | `southcentralus` in the validated run | T4 Flex worker path when `westus3` T4 capacity is unavailable |
| Flex agent pool label | `aksflexnodes` | Placement target for proof workers |
| GPU product label | `nvidia.com/gpu.product=NVIDIA-T4` | Selector required by Anyscale T4 worker pods |
| Anyscale control plane | `https://console.azure.anyscale.com` | Azure-native Anyscale console and Jobs API |
| Proof workload | `workloads/deepspeed_finetune/train.py` | Ray Train + DeepSpeed proof with structured evidence |

## Workshop Flow

| Module | Outcome |
| --- | --- |
| [1 — Environment Setup](docs/ai-workloads-on-aks/module-01-environment-setup.mdx) | Install tools, authenticate, choose CPU or GPU path, check quota |
| [2 — AKS Foundation](docs/ai-workloads-on-aks/module-02-aks-foundation.mdx) | Deploy AKS, storage, ACR, identity, observability, and networking |
| [3 — Flex Node](docs/ai-workloads-on-aks/module-03-flex-node.mdx) | Provision and join the Flex host as a Kubernetes node |
| [4 — Anyscale Binding](docs/ai-workloads-on-aks/module-04-anyscale-binding.mdx) | Create the Anyscale cloud, assign user RBAC, install the AKS extension, verify Gateway API |
| [5 — Preflight Gates](docs/ai-workloads-on-aks/module-05-autoscaling.mdx) | Verify autoscaling, Flex networking, DNS, Gateway, and optional GPU readiness |
| [6 — Workload Proof](docs/ai-workloads-on-aks/module-06-workload-proof.mdx) | Submit CPU/GPU Anyscale Jobs and validate proof summaries plus pod placement |
| [7 — Teardown](docs/ai-workloads-on-aks/module-07-teardown.mdx) | Destroy the lab and verify no current lab resources remain |

## Start Here

Open [AKS Flex Node + Anyscale on Azure](docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx), then follow the modules in order. The main operator command is:

```bash
./scripts/anyscale-aks.sh <doctor|apply|status|destroy>
```

Use `.env-template` as the source for your local `.env`. The CPU path is the cheapest repeatable route. The GPU path requires T4 quota, a GPU-capable Flex host image, the NVIDIA device plugin, and the `NVIDIA-T4` product label applied to the Flex node.

## Success Evidence

A successful run produces proof artifacts under `.cache/anyscale/proofs/`:

- `<proof-name>-proof-summary.json` validates workload output, storage proof, CUDA state, and region hints.
- `<proof-name>-kubernetes-placement.json` proves the Ray worker pod landed on `vm-flex-...` with `node_agentpool="aksflexnodes"`.
- GPU proof summaries should report `cuda_available=true`, `device_name="Tesla T4"`, and `observed_region_hint` matching the Flex region.

The proof path uses Anyscale Jobs. Seeing Jobs without Workspaces in the Anyscale console is expected.

## Teardown

Finish with:

```bash
./scripts/run-lab-e2e.sh teardown
```

The current lab is clean only when the resource group is deleted and `terraform -chdir=infra/terraform state list` returns no resources. Stale Azure Anyscale control-plane entries without backing Azure ARM resources cannot be removed by `anyscale cloud delete`; they require provider-side cleanup.
