# Deepspeed Fine-Tune Proof Workload

This directory holds the first representative workload adaptation for WP-06.
It is based on the Anyscale `deepspeed_finetune` template, but it is adjusted
for this sample in three ways:

1. It defaults to synthetic inputs so runs are repeatable and do not depend on
   external downloads.
2. It writes a machine-readable proof summary to `./evidence/proof-summary.json`.
3. It exposes profile knobs for smoke and full runs so we can separate local
   validation from GPU saturation proofs.

## Files

- `train.py`: Ray Train + DeepSpeed workload entrypoint.
- `proof-schema.json`: schema for the generated proof summary.
- `adaptation-notes.md`: concise notes on how this differs from upstream.

## Current usage intent

The script is meant to run inside the Anyscale-bound AKS cluster once the cloud
binding and compute profile are in place. For a quick local syntax check, run:

```bash
python3 -m py_compile workloads/deepspeed_finetune/train.py
```

The emitted proof summary is intentionally conservative at this stage. It
captures world size, worker identity, region hints, and training metrics so the
later evidence bundle can prove placement and saturation without manual log
inspection.
