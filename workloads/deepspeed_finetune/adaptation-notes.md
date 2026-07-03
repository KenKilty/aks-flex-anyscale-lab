# Deepspeed Fine-Tune Adaptation Notes

Upstream template behavior that was kept:

- Ray Train orchestrates the distributed run.
- DeepSpeed still handles optimizer state partitioning and mixed precision.
- Checkpoint save and resume behavior remains in place.

Changes made for this sample:

- Synthetic token data is the default input source.
- A tiny GPT-2 style config is created locally when synthetic mode is enabled.
- The workload emits a JSON proof summary to a shared evidence directory.
- Region and node hints are captured from environment variables so the proof
  bundle can be correlated with AKS placement evidence later.
- A smoke profile limits worker count, epoch count, and step count so the same
  script can support quick validation and larger GPU pressure tests.

Open follow-up for Module 6:

- Add the launcher wrapper that submits the workload through the Anyscale cloud
  binding once the compute profile is finalized.
- Extend the proof summary with observed region labels from the cluster when
  those labels are available in the runtime environment.
