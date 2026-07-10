# Run AI Where Your GPUs Are

GPU capacity often sits outside the exact region, cluster, or datacenter where a team wants to run its AI workload. AKS Flex Node lets an AKS cluster use Linux compute wherever you can reach it: another Azure region, an on-premises machine, or another cloud environment. Anyscale on Azure adds the Ray control plane on top, so teams can submit Jobs, manage compute profiles, and observe distributed workers without rewriting the workload for each location. Together, Flex Node and Anyscale let you run Ray AI/ML workloads where your compute and GPUs already are.

![Home region AKS cluster with Flex expansion](docs/ai-workloads-on-aks/assets/aks-flex-anyscale-multi-region/01-home-region-flex-expansion.svg)

## What You Will Learn To Do

In this lab, you learn how to keep AKS as the operating surface for an AI workload even when useful compute sits somewhere else. That pattern matters in organizations with GPU quota in one Azure region, existing machines in a datacenter, or accelerator capacity in another cloud environment. AKS Flex Node gives those Linux hosts a way to join the cluster instead of forcing every workload onto one managed node pool.

You will then connect that cluster to Anyscale on Azure and submit Ray Jobs against the combined capacity. Anyscale gives students and platform teams a managed Ray control plane for Jobs, compute profiles, and workload visibility. Flex Node supplies the reachable compute; Anyscale schedules the Ray AI/ML workload onto the capacity profile you define.

The lab keeps the proof visible. The CPU path gives you a low-cost repeatable run. The GPU path schedules a `GPU:1` Ray worker on a Flex-hosted Tesla T4 and proves that pod landed on `agentpool=aksflexnodes`, not on an AKS managed GPU node pool. You also use workload identity to write proof data to Azure Blob Storage without shared keys or SAS tokens, then tear the lab down and verify Terraform state is empty.

## Reference Topology

| Layer | Reference value | Purpose |
| --- | --- | --- |
| Home region | `westus2` | AKS, storage, ACR, observability, Anyscale cloud binding |
| CPU Flex region | `westus3` | Lower-cost cross-region Flex worker path |
| GPU Flex region | `southcentralus` in the validated run | T4 Flex worker path when `westus3` T4 capacity is unavailable |
| Flex agent pool label | `aksflexnodes` | Placement target for proof workers |
| GPU product label | `nvidia.com/gpu.product=NVIDIA-T4` | Selector required by Anyscale T4 worker pods |
| Anyscale control plane | `https://console.azure.anyscale.com` | Anyscale on Azure console and Jobs API |
| Proof workload | `workloads/deepspeed_finetune/train.py` | Ray Train + DeepSpeed proof with structured evidence |

## Workshop Flow

| Module | Outcome |
| --- | --- |
| [1: Environment Setup](docs/ai-workloads-on-aks/module-01-environment-setup.mdx) | Install tools, authenticate, choose CPU or GPU path, check quota |
| [2: AKS Foundation](docs/ai-workloads-on-aks/module-02-aks-foundation.mdx) | Deploy AKS, storage, ACR, identity, observability, and networking |
| [3: Flex Node](docs/ai-workloads-on-aks/module-03-flex-node.mdx) | Provision and join the Flex host as a Kubernetes node |
| [4: Anyscale Binding](docs/ai-workloads-on-aks/module-04-anyscale-binding.mdx) | Create the Anyscale cloud, assign user RBAC, install the AKS extension, verify Gateway API |
| [5: Preflight Gates](docs/ai-workloads-on-aks/module-05-autoscaling.mdx) | Verify autoscaling, Flex networking, DNS, Gateway, and GPU readiness when enabled |
| [6: Workload Proof](docs/ai-workloads-on-aks/module-06-workload-proof.mdx) | Submit CPU/GPU Anyscale Jobs and validate proof summaries plus pod placement |
| [7: Teardown](docs/ai-workloads-on-aks/module-07-teardown.mdx) | Destroy the lab and verify no current lab resources remain |

## Start Here

Open [Run AI Where Your GPUs Are](docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx), then follow the modules in order. The main operator command is:

```bash
./scripts/anyscale-aks.sh <doctor|apply|status|destroy>
```

Use `.env-template` as the source for your local `.env`. The CPU path is the cheapest repeatable route. The GPU path requires T4 quota, a GPU-capable Flex host image, the NVIDIA device plugin, and the `NVIDIA-T4` product label applied to the Flex node.

## Success Evidence

A successful run produces proof artifacts under `.cache/anyscale/proofs/`. The
proof summary validates workload output, storage proof, CUDA state, and region
hints. The Kubernetes placement artifact proves the Ray worker pod landed on a
`vm-flex-...` node with `node_agentpool="aksflexnodes"`.

For the GPU path, the proof summary should report `cuda_available=true`,
`device_name="Tesla T4"`, and an `observed_region_hint` that matches the Flex
region. That combination matters because job success alone does not prove the
worker used Flex GPU capacity.

The proof path uses Anyscale Jobs. Seeing Jobs without Workspaces in the Anyscale console is expected.

## Teardown

Finish with:

```bash
./scripts/run-lab-e2e.sh teardown
```

The current lab is clean only when the resource group is deleted and `terraform -chdir=infra/terraform state list` returns no resources. Stale Azure Anyscale control-plane entries without backing Azure ARM resources cannot be removed by `anyscale cloud delete`; they require provider-side cleanup.
