# Run AI Where Your GPUs Are

GPU capacity often sits outside the exact region, cluster, or datacenter where a team wants to run its AI workload. AKS Flex Node lets an AKS cluster use Linux compute wherever you can reach it: another Azure region, an on-premises machine, or another cloud environment. Anyscale on Azure adds the Ray control plane on top, so teams can submit Jobs, manage compute profiles, and observe distributed workers without rewriting the workload for each location. Together, Flex Node and Anyscale let you run Ray AI/ML workloads where your compute and GPUs already are.

This lab builds that pattern with two peered Azure regions, which keeps it reproducible in any subscription. It does not create an on-premises or other-cloud network path. What you validate here is the join flow, the pod networking between sites, and the proof that one job trained across both locations.

## Start the lab

Open [Run AI Where Your GPUs Are](docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx),
then follow Modules 1 through 7 in order. Module 1 lists the Azure permissions,
local tools, regional quota, and CPU or GPU settings to check before the first
deployment in Module 2.

## Run the documentation locally

The documentation site requires Node.js 22 or later and npm. From the repository
root, install the locked dependencies, then start Docusaurus with the repository
helper:

```bash
npm ci
scripts/docs-dev.sh
```

Open `http://localhost:3000/docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region`
and follow the modules from the browser. This only serves the lab instructions; it
does not create Azure or Anyscale resources until you run the commands inside the
modules. The script restarts the docs server on port 3000 and clears the Docusaurus
cache before serving the site.

## Prepare a deployment

After you sign in with `az login`, bootstrap the local deployment files and run
the read-only environment checks:

```bash
./scripts/anyscale-aks.sh bootstrap
./scripts/anyscale-aks.sh doctor
```

Bootstrap copies `.env-template` to the ignored `.env` file, records the active
Azure subscription and tenant, creates the configured SSH key when needed, and
installs the Anyscale CLI in `.venv`. Review the generated `.env` values in
Module 1 before you create Azure resources.

## What you will learn

In this lab, you learn how to keep AKS as the operating surface for an AI workload even when useful compute sits somewhere else. That pattern matters in organizations with GPU quota in one Azure region, existing machines in a datacenter, or accelerator capacity in another cloud environment. AKS Flex Node gives those Linux hosts a way to join the cluster instead of forcing every workload onto one managed node pool.

You will then connect that cluster to Anyscale on Azure and submit a Ray Job to
the combined capacity. Anyscale manages the Ray Job, compute config, and workload
visibility. Flex Node supplies the reachable compute, and Kubernetes places the
Ray pods on nodes that match the compute config.

Choose the CPU or GPU path supported by quota and capacity in your Azure
environment. The GPU path runs one `GPU:1` Ray Train worker on managed AKS and
one on the configured Flex host in the same two-rank world. You will inspect a
joined proof that records both ranks, both nodes, and concurrent placement. You
will also write workload results to Azure Blob
Storage with workload identity, then remove the environment and confirm that
Terraform state is empty.

## Reference topology

These values are the validated reference shape, not hard-coded requirements. Copy
`.env-template` to `.env`, then change the region and VM-size `TF_VAR_*` values to
match quota and capacity in your subscription. The deployment command passes
those values to Terraform.

| Layer | Reference value | Purpose |
| --- | --- | --- |
| Region A | Value of `TF_VAR_azure_location` | AKS, storage, ACR, observability, Anyscale cloud binding |
| Region B | Value of `TF_VAR_flex_region` | Cross-region Flex worker path for CPU or GPU runs |
| Cluster network model | `networkPlugin=none` with Unbounded pod networking | Single no-CNI path for managed AKS nodes and the Flex node |
| Pod address ranges | `TF_VAR_cilium_pod_cidr` and `TF_VAR_unbounded_flex_pod_cidr` | Non-overlapping pod ranges for managed AKS pods and Flex pods |
| AKS CPU node pool SKU | Value of `TF_VAR_cpu_vm_size` | Home-region CPU pool used when Anyscale needs AKS CPU capacity |
| Flex host SKU | Value of `TF_VAR_flex_host_vm_size` | CPU or GPU VM size selected for the Flex worker |
| Flex host image | Value of `TF_VAR_flex_host_source_image_reference` | Ubuntu 24.04 LTS server by default; a GPU host image must include the NVIDIA driver |
| Flex agent pool label | `aksflexnodes` | Placement target for the external Ray worker |
| GPU product labels | Values in `TF_VAR_gpu_pool_configs` and `ANYSCALE_RESULTS_GPU_PRODUCT_LABEL` | Product selectors for managed and Flex GPU workers |
| Anyscale control plane | `https://console.azure.anyscale.com` | Anyscale on Azure console and Jobs API |
| Workload | `workloads/deepspeed_finetune/train.py` | Ray Train and DeepSpeed workload with structured results |

## Module flow

Work through the modules in order. You start by checking that your subscription,
tools, and chosen CPU or GPU path are ready. Then you build the AKS foundation,
attach a Flex host from a second location, bind the cluster to Anyscale on Azure,
confirm that the workload path is healthy, and run a distributed Ray workload.
The last two modules produce the results you should keep: Anyscale Job output,
summary JSON, Kubernetes placement JSON, and cleanup checks showing that the
Azure resources are gone.

| Module | Outcome |
| --- | --- |
| [1: Prepare Your Environment](docs/ai-workloads-on-aks/module-01-environment-setup.mdx) | Sign in, check tools and quota, and choose the CPU or GPU path |
| [2: Build the AKS Foundation](docs/ai-workloads-on-aks/module-02-aks-foundation.mdx) | Create AKS, the Flex VM, storage, a container registry, identity, observability, and networking |
| [3: Connect a Flex Node](docs/ai-workloads-on-aks/module-03-flex-node.mdx) | Join the provisioned Flex VM to AKS and verify Unbounded pod networking across both regions |
| [4: Connect Anyscale](docs/ai-workloads-on-aks/module-04-anyscale-binding.mdx) | Create the Anyscale cloud, assign user access, install the AKS extension, and verify the Gateway |
| [5: Review Scaling and Readiness](docs/ai-workloads-on-aks/module-05-autoscaling.mdx) | Confirm autoscaling, Flex networking, DNS, Gateway, and GPU availability when selected |
| [6: Run the Workload](docs/ai-workloads-on-aks/module-06-workload-results.mdx) | Submit the Anyscale Job, inspect its results, and confirm pod placement |
| [7: Remove the Environment](docs/ai-workloads-on-aks/module-07-teardown.mdx) | Stop active jobs, delete Azure resources, and confirm cleanup |

## Success evidence

After Module 6, keep the files under `.cache/anyscale/results/`. For GPU mode,
the `<job-name>-dual-gpu-training-proof.json` file matters most. It joins each
rank's loss, step count, CUDA device, node, region, and pool with a timestamp
showing both GPU worker pods were Running concurrently.

For the CPU path, the Ray worker should land on a `vm-flex-...` node with
`node_agentpool="aksflexnodes"`, and its region should match `TF_VAR_flex_region`.
For the GPU path, require `world_size=2`, CUDA and completed steps for both ranks,
one managed GPU pool placement, and one `aksflexnodes` placement. A successful
Anyscale Job alone is not enough.

This lab uses Anyscale Jobs. Seeing Jobs without Workspaces in the Anyscale
console is expected.

## Teardown

Finish with:

```bash
./scripts/anyscale-aks.sh destroy
./scripts/validate-lab.sh teardown
```

The current lab is clean only when the lab resource group and the AKS-managed
resource group are deleted and `terraform -chdir=infra/terraform state list`
returns no resources. This lab deletes its Anyscale cloud through the Azure
`Anyscale.Platform` resource provider. If the console retains a cloud shell after
its backing ARM resource is gone, provider-side cleanup is required because a
second infrastructure delete cannot reconcile control-plane metadata.

## Develop and contribute

[Contributing to This Lab](CONTRIBUTING.md) describes the workshop scope and
submission expectations. The [Developer Guide](docs/DEVELOPER.md) covers the
repository structure, authoring conventions, validation commands, live E2E
workflow, and pull request checklist.

Before you propose a change, run:

```bash
scripts/lint.sh
npm run build
```

## Related documentation

- [Azure Kubernetes Service documentation](https://learn.microsoft.com/azure/aks/)
- [Kubernetes documentation](https://kubernetes.io/docs/)
- [Ray documentation](https://docs.ray.io/en/latest/)
- [Anyscale documentation](https://docs.anyscale.com/)

## License

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md).
