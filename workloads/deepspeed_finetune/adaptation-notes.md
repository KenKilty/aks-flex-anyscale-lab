# Deepspeed Fine-Tune Implementation Notes

The workload keeps these core behaviors:

- Ray Train orchestrates the distributed run.
- DeepSpeed still handles optimizer state partitioning and mixed precision.
- Checkpoint save and resume behavior remains in place.

Lab-specific behavior:

- Synthetic token data is the default input source.
- A tiny GPT-2 style config is created locally when synthetic mode is enabled.
- The workload emits a JSON proof summary to stdout for Anyscale log capture.
- When `ANYSCALE_PROOF_STORAGE_ACCOUNT` and `ANYSCALE_PROOF_STORAGE_CONTAINER`
  are set, the workload writes and reads the proof summary through `az://`
  storage using workload identity.
- Region and node hints are captured from environment variables so the proof
  bundle can be correlated with AKS placement evidence.
- A smoke profile limits worker count, epoch count, and step count so the same
  script can support quick validation and larger GPU pressure tests.
