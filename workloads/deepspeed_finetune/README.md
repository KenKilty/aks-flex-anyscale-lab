# DeepSpeed Fine-Tune Proof Workload

This directory contains the representative Ray Train + DeepSpeed proof workload
for the lab. It is adapted for this sample in three ways:

1. It defaults to synthetic inputs so runs are repeatable and do not depend on
   external downloads.
2. It emits a machine-readable proof summary in job logs and, when storage
   environment variables are provided, writes the same summary through managed
   identity to `az://` storage.
3. It exposes smoke/full profile knobs so the same script can support quick CPU
   validation and larger GPU pressure tests.

## Files

- `train.py`: Ray Train + DeepSpeed workload entrypoint.
- `proof-schema.json`: schema for the generated proof summary.
- `adaptation-notes.md`: implementation notes for the workload.

## Usage

Run a local CPU smoke check:

```bash
./scripts/run-workload-smoke.sh
```

Submit the CPU proof through Anyscale after completing the operator and compute
configuration modules:

```bash
./scripts/run-anyscale-proof.sh --mode cpu
```

See [Module 6](../../docs/ai-workloads-on-aks/module-06-workload-proof.mdx) for
the full proof workflow.
