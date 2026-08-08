# DeepSpeed fine-tune workload behavior

The workload keeps these core behaviors:

- Ray Train orchestrates the distributed run.
- DeepSpeed still handles optimizer state partitioning and mixed precision.
- Checkpoint save and resume behavior remains in place.

Configuration used in Module 6:

- Synthetic token data is the default input source.
- A tiny GPT-2 style config is created locally when synthetic mode is enabled.
- The workload emits a JSON summary to stdout for Anyscale log capture.
- When `ANYSCALE_RESULTS_STORAGE_ACCOUNT` and `ANYSCALE_RESULTS_STORAGE_CONTAINER`
  are set, the workload writes and reads the summary through `az://`
  storage using workload identity.
- Region and node hints are captured from environment variables so the summary
  can be compared with AKS placement data.
- A smoke profile limits worker count, epoch count, and step count so the same
  script can support quick validation and larger GPU pressure tests.
