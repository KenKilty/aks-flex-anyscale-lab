#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import NoReturn

REQUIRED_TOP_LEVEL_KEYS = {
    "run_id",
    "experiment_name",
    "local_smoke",
    "placement",
    "worker_snapshot",
    "runtime_versions",
    "metrics",
    "status",
}

ALLOWED_STATUS = {"draft", "passed", "failed"}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"workload summary validation failed: {message}")


def validate_summary(
    summary: dict[str, object],
    expected_worker_region: str | None,
    expected_worker_count: int | None,
    require_cuda: bool,
) -> None:
    missing = sorted(REQUIRED_TOP_LEVEL_KEYS.difference(summary))
    if missing:
        fail(f"missing top-level keys: {', '.join(missing)}")

    if summary["status"] not in ALLOWED_STATUS:
        fail("status must be draft, passed, or failed")

    placement = summary["placement"]
    worker_snapshot = summary["worker_snapshot"]
    runtime_versions = summary["runtime_versions"]
    metrics = summary["metrics"]
    local_smoke = summary["local_smoke"] is True
    storage_result = summary.get("storage_result")
    worker_snapshots = summary.get("worker_snapshots")

    if not isinstance(placement, dict):
        fail("placement must be an object")
    if not isinstance(worker_snapshot, dict):
        fail("worker_snapshot must be an object")
    if not isinstance(runtime_versions, dict):
        fail("runtime_versions must be an object")
    if not isinstance(metrics, dict):
        fail("metrics must be an object")
    if storage_result is None and not local_smoke:
        fail("missing top-level key: storage_result")
    if storage_result is not None and not isinstance(storage_result, dict):
        fail("storage_result must be an object")
    if expected_worker_count is not None:
        if not isinstance(worker_snapshots, list):
            fail("worker_snapshots must be an array")
        if len(worker_snapshots) != expected_worker_count:
            fail(
                f"worker_snapshots must contain {expected_worker_count} workers; "
                f"got {len(worker_snapshots)}"
            )
        expected_ranks = list(range(expected_worker_count))
        observed_ranks = sorted(
            int(worker.get("rank", -1)) for worker in worker_snapshots if isinstance(worker, dict)
        )
        if observed_ranks != expected_ranks:
            fail(f"worker snapshot ranks must be {expected_ranks}; got {observed_ranks}")
        if require_cuda and any(
            not isinstance(worker, dict) or worker.get("cuda_available") is not True
            for worker in worker_snapshots
        ):
            fail("every worker snapshot must report cuda_available=true")

    for key in ("expected_regions", "observed_world_size"):
        if key not in placement:
            fail(f"placement missing key: {key}")

    if expected_worker_region is not None:
        observed_region = str(placement.get("observed_region_hint", "")).strip()
        worker_region = str(worker_snapshot.get("region_hint", "")).strip()
        if observed_region != expected_worker_region:
            fail(
                "placement observed_region_hint must match expected worker region "
                f"{expected_worker_region}; got {observed_region or 'empty'}"
            )
        if worker_region != expected_worker_region:
            fail(
                "worker_snapshot region_hint must match expected worker region "
                f"{expected_worker_region}; got {worker_region or 'empty'}"
            )

    for key in ("run_id", "rank", "world_size", "hostname", "cuda_available", "device_name"):
        if key not in worker_snapshot:
            fail(f"worker_snapshot missing key: {key}")

    for key in (
        "python",
        "ray",
        "cloudpickle",
        "adlfs",
        "fsspec",
        "deepspeed",
        "torch",
        "transformers",
    ):
        if not str(runtime_versions.get(key, "")).strip():
            fail(f"runtime_versions missing key: {key}")

    for key in ("epoch", "loss", "num_batches", "steps_per_worker", "world_size"):
        if key not in metrics:
            fail(f"metrics missing key: {key}")

    if storage_result is not None:
        for key in ("account_name", "container_name", "client_id_present", "path", "uri"):
            if key not in storage_result:
                fail(f"storage_result missing key: {key}")

        if not str(storage_result["uri"]).startswith("az://"):
            fail("storage_result uri must use az://")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description="Validate an AKS Flex workload summary")
    parser.add_argument("summary_json")
    parser.add_argument("--expected-worker-region")
    parser.add_argument("--expected-worker-count", type=int)
    parser.add_argument("--require-cuda", action="store_true")
    args = parser.parse_args(argv[1:])

    summary_path = Path(args.summary_json)
    if not summary_path.is_file():
        fail(f"file not found: {summary_path}")

    with summary_path.open("r", encoding="utf-8") as stream:
        summary = json.load(stream)

    if not isinstance(summary, dict):
        fail("summary root must be a JSON object")

    validate_summary(
        summary,
        args.expected_worker_region,
        args.expected_worker_count,
        args.require_cuda,
    )
    print(f"validated: {summary_path}")


if __name__ == "__main__":
    main(sys.argv)
