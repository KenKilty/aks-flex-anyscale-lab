#!/usr/bin/env python3

"""Representative GPU workload proof for the AKS Flex sample.

This is a script-first adaptation of the Anyscale deepspeed_finetune template.
It defaults to synthetic inputs so the proof is repeatable and does not depend
on external model or dataset downloads.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

os.environ.setdefault("RAY_TRAIN_V2_ENABLED", "1")

import deepspeed
import ray
import ray.train
import ray.train.torch
import torch
from ray.train import Checkpoint, RunConfig, ScalingConfig
from ray.train.torch import TorchTrainer
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForCausalLM, GPT2Config

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class WorkerSnapshot:
    run_id: str
    experiment_name: str
    rank: int
    world_size: int
    hostname: str
    cuda_available: bool
    device_name: str
    region_hint: str
    node_hint: str


class SyntheticTokenDataset(Dataset):
    def __init__(self, sample_count: int, sequence_length: int, vocab_size: int, seed: int) -> None:
        self.sample_count = sample_count
        self.sequence_length = sequence_length
        self.vocab_size = vocab_size
        self.seed = seed

    def __len__(self) -> int:
        return self.sample_count

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        generator = torch.Generator().manual_seed(self.seed + index)
        input_ids = torch.randint(
            low=0,
            high=self.vocab_size,
            size=(self.sequence_length,),
            generator=generator,
            dtype=torch.long,
        )
        attention_mask = torch.ones_like(input_ids)
        return {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }


def log_rank0(message: str) -> None:
    if ray.train.get_context().get_world_rank() == 0:
        logger.info(message)


def get_precision_config() -> dict[str, Any]:
    if not torch.cuda.is_available():
        return {}
    if torch.cuda.is_bf16_supported():
        return {"bf16": {"enabled": True}, "grad_accum_dtype": "bf16"}
    return {"fp16": {"enabled": True}}


def build_tiny_model(
    vocab_size: int, sequence_length: int, hidden_size: int, layers: int, heads: int
) -> Any:
    config = GPT2Config(
        vocab_size=vocab_size,
        n_positions=sequence_length,
        n_ctx=sequence_length,
        n_embd=hidden_size,
        n_layer=layers,
        n_head=heads,
        bos_token_id=0,
        eos_token_id=1,
    )
    return AutoModelForCausalLM.from_config(config)


def setup_model_and_optimizer(
    model_name: str,
    learning_rate: float,
    ds_config: dict[str, Any],
    synthetic_model: bool,
    vocab_size: int,
    sequence_length: int,
    hidden_size: int,
    layers: int,
    heads: int,
) -> deepspeed.runtime.engine.DeepSpeedEngine:
    if synthetic_model:
        model = build_tiny_model(vocab_size, sequence_length, hidden_size, layers, heads)
        log_rank0(
            f"Synthetic model loaded (#parameters: {sum(parameter.numel() for parameter in model.parameters())})"
        )
    else:
        model = AutoModelForCausalLM.from_pretrained(model_name)
        log_rank0(
            f"Model loaded: {model_name} (#parameters: {sum(parameter.numel() for parameter in model.parameters())})"
        )

    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate)
    ds_engine, _, _, _ = deepspeed.initialize(model=model, optimizer=optimizer, config=ds_config)
    return ds_engine


def setup_dataloader(
    sample_count: int,
    batch_size: int,
    sequence_length: int,
    vocab_size: int,
    seed: int,
) -> DataLoader:
    dataset = SyntheticTokenDataset(sample_count, sequence_length, vocab_size, seed)

    data_loader = DataLoader(dataset, batch_size=batch_size, shuffle=True, drop_last=True)
    return ray.train.torch.prepare_data_loader(data_loader)


def capture_worker_snapshot(run_id: str, experiment_name: str) -> WorkerSnapshot:
    context = ray.train.get_context()
    hostname = socket.gethostname()
    device_name = (
        torch.cuda.get_device_name(torch.cuda.current_device())
        if torch.cuda.is_available()
        else "cpu"
    )
    return WorkerSnapshot(
        run_id=run_id,
        experiment_name=experiment_name,
        rank=context.get_world_rank(),
        world_size=context.get_world_size(),
        hostname=hostname,
        cuda_available=torch.cuda.is_available(),
        device_name=device_name,
        region_hint=os.environ.get("AKS_NODE_REGION", os.environ.get("AZURE_REGION", "unknown")),
        node_hint=os.environ.get("NODE_NAME", hostname),
    )


def save_summary(summary_path: Path, summary: dict[str, Any]) -> None:
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    with summary_path.open("w", encoding="utf-8") as stream:
        json.dump(summary, stream, indent=2, sort_keys=True)
        stream.write("\n")


def write_storage_proof(summary: dict[str, Any], run_id: str) -> dict[str, Any] | None:
    account_name = os.environ.get("ANYSCALE_PROOF_STORAGE_ACCOUNT", "").strip()
    container_name = os.environ.get("ANYSCALE_PROOF_STORAGE_CONTAINER", "").strip()
    if not account_name or not container_name:
        return None

    import fsspec

    storage_path = f"{container_name}/anyscale/proofs/{run_id}/proof-summary.json"
    storage_uri = f"az://{storage_path}"
    abfss_uri = f"abfss://{container_name}@{account_name}.dfs.core.windows.net/anyscale/proofs/{run_id}/proof-summary.json"
    storage_proof = {
        "account_name": account_name,
        "abfss_uri": abfss_uri,
        "container_name": container_name,
        "client_id_present": bool(os.environ.get("AZURE_CLIENT_ID")),
        "path": storage_path,
        "uri": storage_uri,
    }
    summary["storage_proof"] = storage_proof
    payload = json.dumps(summary, indent=2, sort_keys=True).encode("utf-8") + b"\n"

    filesystem = fsspec.filesystem("az", account_name=account_name, anon=False)
    filesystem.makedirs(f"{container_name}/anyscale/proofs/{run_id}", exist_ok=True)
    with filesystem.open(storage_path, "wb") as stream:
        stream.write(payload)
    with filesystem.open(storage_path, "rb") as stream:
        round_trip = stream.read()

    if round_trip != payload:
        raise RuntimeError(
            "managed identity storage proof round trip did not match written payload"
        )

    return storage_proof


def load_checkpoint(
    ds_engine: deepspeed.runtime.engine.DeepSpeedEngine, checkpoint: Checkpoint
) -> int:
    next_epoch = 0
    with checkpoint.as_directory() as checkpoint_dir:
        ds_engine.load_checkpoint(checkpoint_dir)
        epoch_file = Path(checkpoint_dir) / "epoch.txt"
        if epoch_file.is_file():
            next_epoch = int(epoch_file.read_text(encoding="utf-8").strip()) + 1
    return next_epoch


def report_metrics_and_save_checkpoint(
    ds_engine: deepspeed.runtime.engine.DeepSpeedEngine,
    metrics: dict[str, Any],
    run_id: str,
    summary_dir: Path,
    profile: str,
    smoke_mode: bool,
    synthetic_model: bool,
    expected_regions: list[str],
    placement_hint_env: str,
    checkpoint_enabled: bool,
) -> None:
    context = ray.train.get_context()
    snapshot = capture_worker_snapshot(run_id, context.get_experiment_name())
    report_payload = {
        **metrics,
        "run_id": run_id,
        "profile": profile,
        "smoke_mode": smoke_mode,
        "synthetic_model": synthetic_model,
        "world_rank": snapshot.rank,
        "world_size": snapshot.world_size,
        "hostname": snapshot.hostname,
        "region_hint": snapshot.region_hint,
        "node_hint": snapshot.node_hint,
    }

    if checkpoint_enabled:
        with tempfile.TemporaryDirectory() as tmp_dir:
            checkpoint_dir = Path(tmp_dir) / "checkpoint"
            checkpoint_dir.mkdir(parents=True, exist_ok=True)
            ds_engine.save_checkpoint(str(checkpoint_dir))
            (checkpoint_dir / "epoch.txt").write_text(str(metrics["epoch"]), encoding="utf-8")

            checkpoint = Checkpoint.from_directory(tmp_dir)
            ray.train.report(report_payload, checkpoint=checkpoint)
    else:
        ray.train.report(report_payload)

    if context.get_world_rank() == 0:
        summary_path = summary_dir / "proof-summary.json"
        summary = {
            "run_id": run_id,
            "experiment_name": context.get_experiment_name(),
            "profile": profile,
            "smoke_mode": smoke_mode,
            "synthetic_model": synthetic_model,
            "timestamp_unix": int(time.time()),
            "placement": {
                "expected_regions": expected_regions,
                "placement_hint_env": placement_hint_env,
                "observed_region_hint": snapshot.region_hint,
                "observed_node_hint": snapshot.node_hint,
                "observed_world_size": snapshot.world_size,
            },
            "worker_snapshot": asdict(snapshot),
            "metrics": metrics,
            "status": "passed",
        }
        write_storage_proof(summary, run_id)
        save_summary(summary_path, summary)
        print(
            f"PROOF_SUMMARY_JSON={json.dumps(summary, sort_keys=True, separators=(',', ':'))}",
            flush=True,
        )


def train_loop(config: dict[str, Any]) -> None:
    ds_config = dict(config["ds_config"])
    ds_config.update(get_precision_config())

    ds_engine = setup_model_and_optimizer(
        config["model_name"],
        config["learning_rate"],
        ds_config,
        config["synthetic_model"],
        config["vocab_size"],
        config["sequence_length"],
        config["hidden_size"],
        config["layers"],
        config["heads"],
    )

    checkpoint = ray.train.get_checkpoint()
    start_epoch = 0
    if checkpoint:
        start_epoch = load_checkpoint(ds_engine, checkpoint)

    train_loader = setup_dataloader(
        sample_count=config["sample_count"],
        batch_size=config["batch_size"],
        sequence_length=config["sequence_length"],
        vocab_size=config["vocab_size"],
        seed=config["seed"],
    )
    device = torch.device("cpu") if config["cpu_only"] else ray.train.torch.get_device()
    ds_engine.train()

    summary_dir = Path(config["evidence_dir"])
    run_id = config["run_id"]

    for epoch in range(start_epoch, config["epochs"]):
        sampler = getattr(train_loader, "sampler", None)
        if sampler and hasattr(sampler, "set_epoch"):
            sampler.set_epoch(epoch)

        running_loss = 0.0
        num_batches = 0

        for step, batch in enumerate(train_loader):
            input_ids = batch["input_ids"].to(device)
            attention_mask = batch["attention_mask"].to(device)

            outputs = ds_engine(
                input_ids=input_ids,
                attention_mask=attention_mask,
                labels=input_ids,
                use_cache=False,
            )
            loss = outputs.loss

            ds_engine.backward(loss)
            ds_engine.step()

            running_loss += loss.item()
            num_batches += 1

            if config["debug_steps"] > 0 and step + 1 >= config["debug_steps"]:
                log_rank0(f"Stopping early at debug step {config['debug_steps']}.")
                break

        mean_loss = running_loss / max(num_batches, 1)
        metrics = {
            "epoch": epoch,
            "loss": mean_loss,
            "num_batches": num_batches,
            "steps_per_worker": step + 1 if num_batches else 0,
            "world_size": ray.train.get_context().get_world_size(),
        }
        report_metrics_and_save_checkpoint(
            ds_engine,
            metrics,
            run_id=run_id,
            summary_dir=summary_dir,
            profile=config["profile"],
            smoke_mode=config["smoke_mode"],
            synthetic_model=config["synthetic_model"],
            expected_regions=config["expected_regions"],
            placement_hint_env=config["placement_hint_env"],
            checkpoint_enabled=config["checkpoint_enabled"],
        )


def build_train_config(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "run_id": args.run_id,
        "profile": args.profile,
        "smoke_mode": args.profile == "smoke",
        "synthetic_model": True,
        "model_name": args.model_name,
        "learning_rate": args.learning_rate,
        "batch_size": args.batch_size,
        "epochs": args.epochs,
        "sequence_length": args.sequence_length,
        "sample_count": args.sample_count,
        "vocab_size": args.vocab_size,
        "hidden_size": args.hidden_size,
        "layers": args.layers,
        "heads": args.heads,
        "seed": args.seed,
        "debug_steps": args.debug_steps,
        "evidence_dir": args.evidence_dir,
        "checkpoint_enabled": args.enable_checkpoints,
        "cpu_only": args.cpu_only,
        "expected_regions": args.expected_regions,
        "placement_hint_env": args.placement_hint_env,
        "ds_config": {
            "train_micro_batch_size_per_gpu": args.batch_size,
            "zero_optimization": {
                "stage": args.zero_stage,
                "overlap_comm": True,
                "contiguous_gradients": True,
            },
            "gradient_clipping": 1.0,
        },
    }


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AKS Flex deepspeed_finetune proof workload")
    parser.add_argument("--run-id", default=f"proof-{uuid.uuid4().hex[:8]}")
    parser.add_argument("--profile", default="smoke", choices=["smoke", "full"])
    parser.add_argument("--model-name", default="gpt2")
    parser.add_argument("--learning-rate", type=float, default=1e-6)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--sequence-length", type=int, default=256)
    parser.add_argument("--sample-count", type=int, default=64)
    parser.add_argument("--vocab-size", type=int, default=50257)
    parser.add_argument("--hidden-size", type=int, default=128)
    parser.add_argument("--layers", type=int, default=2)
    parser.add_argument("--heads", type=int, default=2)
    parser.add_argument("--num-workers", type=int, default=2)
    parser.add_argument("--zero-stage", type=int, default=2)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--debug-steps", type=int, default=0)
    parser.add_argument("--evidence-dir", default="./evidence")
    parser.add_argument(
        "--expected-regions",
        nargs="+",
        default=["westus3", "westus2"],
        help="Region labels that the proof should eventually cover.",
    )
    parser.add_argument(
        "--placement-hint-env",
        default="AKS_NODE_REGION",
        help="Environment variable used to hint the node region in evidence output.",
    )
    parser.add_argument(
        "--storage-path",
        default="/tmp/anyscale-proof-ray-train",
        help="Shared storage path for Ray Train checkpoints when --enable-checkpoints is set.",
    )
    parser.add_argument(
        "--enable-checkpoints",
        action="store_true",
        help="Persist Ray Train checkpoints to --storage-path.",
    )
    parser.add_argument(
        "--cpu-only",
        action="store_true",
        help="Disable GPU usage for local smoke validation.",
    )
    return parser


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    parser = build_argument_parser()
    args = parser.parse_args()
    if args.profile == "smoke":
        args.num_workers = min(args.num_workers, 2)
        args.epochs = min(args.epochs, 1)
        args.debug_steps = args.debug_steps or 4
        args.sample_count = min(args.sample_count, 64)

    if ray.is_initialized():
        ray.shutdown()

    ray.init(
        runtime_env={
            "env_vars": {"RAY_TRAIN_V2_ENABLED": "1"},
        },
    )

    train_config = build_train_config(args)
    scaling_config = ScalingConfig(num_workers=args.num_workers, use_gpu=not args.cpu_only)
    if args.enable_checkpoints:
        Path(args.storage_path).mkdir(parents=True, exist_ok=True)
        run_config = RunConfig(storage_path=args.storage_path, name=args.run_id)
    else:
        run_config = RunConfig(name=args.run_id)

    trainer = TorchTrainer(
        train_loop_per_worker=train_loop,
        train_loop_config=train_config,
        scaling_config=scaling_config,
        run_config=run_config,
    )

    result = trainer.fit()
    print(f"Training finished. Result: {result}")


if __name__ == "__main__":
    main()
