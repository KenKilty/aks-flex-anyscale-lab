# Run AI Where Your GPUs Are

Useful computing power does not always sit in the same place as the system that
needs it. [AKS Flex Node](https://github.com/Azure/AKSFlexNode) lets a reachable
Linux machine **outside** standard AKS node pools join an AKS cluster as a worker.
That machine could run in another Azure region, a datacenter, or another cloud,
as long as it can reach the AKS cluster over the network.

This lab builds and validates the Azure multi-region implementation of that
pattern. You create AKS in one Azure region, connect a Linux virtual machine from
a second region, and run a small distributed model-training exercise across the
combined computing power. The same Flex Node concepts apply outside Azure, but
the lab does not create a datacenter or other-cloud network path.

[Anyscale on Azure](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/)
records the training Job and its results. An operator inside AKS polls Anyscale
over an outbound connection, creates the Ray resources through the Kubernetes
API, and lets Kubernetes place the work on matching machines. You then compare
training records with Kubernetes placement data to prove where each part ran.

## Start the lab

Open [Run AI Where Your GPUs Are](docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region.mdx),
read [Key Concepts](docs/ai-workloads-on-aks/key-concepts.mdx), then follow
Modules 1 through 7 in order. Key Concepts explains Ray, AKS Flex Node, Anyscale,
and the network in beginner-friendly terms. Module 1 lists the Azure permissions,
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

After you sign in with `az login`, bootstrap the local deployment files. Choose
two regions, then list the CPU or GPU VM SKUs with quota in both:

```bash
./scripts/anyscale-aks.sh bootstrap
REGION_A="<region-a>"
REGION_B="<region-b>"
./scripts/anyscale-aks.sh sku-options "$REGION_A" "$REGION_B" cpu
```

Save both regions and one shared worker SKU from that output in `.env`, then
validate the complete profile:

```bash
./scripts/anyscale-aks.sh doctor
```

Bootstrap copies `.env-template` to the ignored `.env` file, records the active
Azure subscription and tenant, creates the configured SSH key when needed, and
installs the Anyscale CLI in `.venv`. Review the generated `.env` values in
Module 1 before you create Azure resources.

## What you will learn

The workflow is a small, repeatable version of an AI/ML practitioner's
distributed model-training workflow. You prepare computing resources, submit a
training job, let Ray Train and DeepSpeed coordinate the workers, and inspect
the training result and worker placement. These are the same broad steps used
when training or fine-tuning a language model.

The exercise performs real training operations, but it is intentionally small.
The script creates a tiny GPT-2-style model from scratch, generates practice
inputs, measures prediction error, and updates the model's internal weights. It
runs only four training steps so the result is quick and repeatable. Unlike a
real fine-tuning project, it does not use a pretrained model or meaningful
training data, and it does not produce a useful trained model.

Choose the CPU or GPU path supported by quota and capacity in your Azure
environment. Both paths run two training workers: one on managed AKS in Region A
and one on Flex in Region B. CPU mode uses CPU workers, while GPU mode uses GPU
workers. Each worker has a unique world rank within the same two-worker run. You
will compare completed training records with Kubernetes data showing the node,
pool, and region where each worker ran. You will also write results to Azure
Blob Storage with workload identity, then remove the environment and confirm
that Terraform state is empty.

## Reference topology

These values are the validated reference shape, not hard-coded requirements. Copy
`.env-template` to `.env`, use `sku-options` to find one worker SKU with quota
in both regions, then save that same SKU for the Region A worker pool and Region
B Flex node VM. The deployment command passes those values to Terraform.

| Layer | Reference value | Purpose |
| --- | --- | --- |
| Region A | Value of `TF_VAR_azure_location` | AKS, storage, ACR, observability, Anyscale cloud binding |
| Region B | Value of `TF_VAR_flex_region` | Cross-region Flex worker path for CPU or GPU runs |
| Cluster network model | `networkPlugin=none` with [Unbounded](https://github.com/Azure/unbounded) | Unbounded provides pod and service networking because AKS does not install a CNI plugin |
| Pod address ranges | `TF_VAR_aks_pod_cidr` and `TF_VAR_unbounded_flex_pod_cidr` | Non-overlapping pod ranges for managed AKS pods and Flex pods |
| AKS CPU node pool SKU | Value of `TF_VAR_cpu_vm_size` | Home-region CPU pool used when Anyscale needs AKS CPU capacity |
| Flex host SKU | Value of `TF_VAR_flex_host_vm_size` | CPU or GPU VM size selected for the Flex worker |
| Flex host image | Value of `TF_VAR_flex_host_source_image_reference` | Ubuntu 24.04 LTS server by default; a GPU host image must include the NVIDIA driver |
| Flex agent pool label | `aksflexnodes` | Placement target for the external Ray worker |
| GPU product labels | Values in `TF_VAR_gpu_pool_configs` and `ANYSCALE_RESULTS_GPU_PRODUCT_LABEL` | Product selectors for managed and Flex GPU workers |
| Anyscale control plane | `https://console.azure.anyscale.com` | Anyscale on Azure console and Jobs API |
| Workload | `workloads/deepspeed_finetune/train.py` | Tiny synthetic Ray Train and DeepSpeed exercise that performs real training steps and writes structured results |

## Module flow

Work through the modules in order. You start by checking that your subscription,
tools, and chosen CPU or GPU path are ready. Then you deploy AKS and its Azure resources,
attach a Flex host from a second location, bind the cluster to Anyscale on Azure,
confirm that the workload path is healthy, and run a distributed Ray workload.
The last two modules produce the results you should keep: Anyscale Job output,
summary JSON, Kubernetes placement JSON, and cleanup checks showing that the
Azure resources are gone.

| Module | Outcome |
| --- | --- |
| [1: Prepare Your Environment](docs/ai-workloads-on-aks/module-01-environment-setup.mdx) | Sign in, check tools and quota, and choose the CPU or GPU path |
| [2: Deploy AKS and Azure Resource](docs/ai-workloads-on-aks/module-02-aks-foundation.mdx) | Create AKS, the Flex VM, storage, a container registry, identity, observability, and networking |
| [3: Connect a Flex Node](docs/ai-workloads-on-aks/module-03-flex-node.mdx) | Join the provisioned Flex VM to AKS and verify Unbounded pod networking across both regions |
| [4: Connect Anyscale](docs/ai-workloads-on-aks/module-04-anyscale-binding.mdx) | Create the Anyscale cloud, assign user access, install the AKS extension, and verify the Gateway |
| [5: Review Scaling and Readiness](docs/ai-workloads-on-aks/module-05-autoscaling.mdx) | Confirm autoscaling, Flex networking, DNS, Gateway, and GPU availability when selected |
| [6: Run the Workload](docs/ai-workloads-on-aks/module-06-workload-results.mdx) | Submit the small training exercise, inspect its results, and prove which machines ran the workers |
| [7: Remove the Environment](docs/ai-workloads-on-aks/module-07-teardown.mdx) | Stop active jobs, delete Azure resources, and confirm cleanup |

## Success evidence

After Module 6, keep the files under `.cache/anyscale/results/`. For GPU mode,
the `<job-name>-dual-gpu-training-proof.json` file matters most. It joins each
training process's rank, prediction error (loss), step count, CUDA device, node,
region, and pool with a timestamp showing both GPU worker pods were Running
concurrently.

For the CPU path, one Ray worker should use `node_agentpool="cpu"` in Region A,
and the other should land on a `vm-flex-...` node with
`node_agentpool="aksflexnodes"` in Region B.
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
