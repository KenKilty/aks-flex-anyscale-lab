# DeepSpeed Fine-Tune Workload

This directory contains the Ray Train and DeepSpeed workload used in Module 6.
The workload:

1. It defaults to synthetic inputs so runs are repeatable and do not depend on
   external downloads.
2. It emits a machine-readable summary in job logs and, when storage
   environment variables are provided, writes the same summary through managed
   identity to `az://` storage.
3. It records Python, Ray, cloudpickle, DeepSpeed, Torch, and Transformers
   versions in the summary for worker failure comparisons.
4. It exposes smoke/full profile knobs so the same script can support quick CPU
   validation and larger GPU pressure tests.

## Files

- `train.py`: Ray Train + DeepSpeed workload entrypoint.
- `workload-summary-schema.json`: schema for the generated workload summary.
- `adaptation-notes.md`: workload behavior and configuration notes.

## Usage

Run a local CPU smoke check:

```bash
./scripts/run-workload-smoke.sh
```

Submit the CPU workload through Anyscale after completing Modules 1 through 5:

```bash
./scripts/run-anyscale-workload.sh --mode cpu
```

See [Module 6](../../docs/ai-workloads-on-aks/module-06-workload-results.mdx) for
the complete workflow and expected results.
