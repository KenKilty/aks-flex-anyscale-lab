#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import NoReturn

REQUIRED_TOP_LEVEL_KEYS = {
    "run_id",
    "experiment_name",
    "placement",
    "worker_snapshot",
    "metrics",
    "storage_proof",
    "status",
}

ALLOWED_STATUS = {"draft", "passed", "failed"}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"proof summary validation failed: {message}")


def validate_summary(summary: dict[str, object]) -> None:
    missing = sorted(REQUIRED_TOP_LEVEL_KEYS.difference(summary))
    if missing:
        fail(f"missing top-level keys: {', '.join(missing)}")

    if summary["status"] not in ALLOWED_STATUS:
        fail("status must be draft, passed, or failed")

    placement = summary["placement"]
    worker_snapshot = summary["worker_snapshot"]
    metrics = summary["metrics"]
    storage_proof = summary["storage_proof"]

    if not isinstance(placement, dict):
        fail("placement must be an object")
    if not isinstance(worker_snapshot, dict):
        fail("worker_snapshot must be an object")
    if not isinstance(metrics, dict):
        fail("metrics must be an object")
    if not isinstance(storage_proof, dict):
        fail("storage_proof must be an object")

    for key in ("expected_regions", "observed_world_size"):
        if key not in placement:
            fail(f"placement missing key: {key}")

    for key in ("run_id", "rank", "world_size", "hostname", "cuda_available", "device_name"):
        if key not in worker_snapshot:
            fail(f"worker_snapshot missing key: {key}")

    for key in ("epoch", "loss", "num_batches", "steps_per_worker", "world_size"):
        if key not in metrics:
            fail(f"metrics missing key: {key}")

    for key in ("account_name", "container_name", "client_id_present", "path", "uri"):
        if key not in storage_proof:
            fail(f"storage_proof missing key: {key}")

    if not str(storage_proof["uri"]).startswith("az://"):
        fail("storage_proof uri must use az://")


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        raise SystemExit("usage: validate_proof_summary.py <summary.json>")

    summary_path = Path(argv[1])
    if not summary_path.is_file():
        fail(f"file not found: {summary_path}")

    with summary_path.open("r", encoding="utf-8") as stream:
        summary = json.load(stream)

    if not isinstance(summary, dict):
        fail("summary root must be a JSON object")

    validate_summary(summary)
    print(f"validated: {summary_path}")


if __name__ == "__main__":
    main(sys.argv)
