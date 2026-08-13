#!/usr/bin/env python3
"""Reject Anyscale CLI operations that can fall back to the default cloud."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "scripts"
ANYSCALE_TERRAFORM = ROOT / "infra" / "terraform" / "anyscale.tf"
ANYSCALE_COMMAND = re.compile(
    r"(?:\.venv/bin/anyscale|\$\{ANYSCALE_VENV_DIR\}/bin/anyscale|"
    r'"\$\{ANYSCALE_VENV_DIR\}/bin/anyscale"|(?<![/\w])anyscale)\s+'
    r"(cloud|job|service|workspace_v2|compute-config)\s+([a-z0-9_-]+)"
)


def command_blocks(source: str) -> list[tuple[int, str]]:
    lines = source.splitlines()
    blocks: list[tuple[int, str]] = []
    covered: set[int] = set()

    index = 0
    while index < len(lines):
        if re.search(r"=\(\s*$", lines[index]):
            start = index
            depth = lines[index].count("(") - lines[index].count(")")
            index += 1
            while index < len(lines) and depth > 0:
                depth += lines[index].count("(") - lines[index].count(")")
                index += 1
            block = "\n".join(lines[start:index])
            if ANYSCALE_COMMAND.search(block):
                blocks.append((start + 1, block))
                covered.update(range(start, index))
            continue
        index += 1

    index = 0
    while index < len(lines):
        if index in covered or not ANYSCALE_COMMAND.search(lines[index]):
            index += 1
            continue
        start = index
        block_lines = [lines[index]]
        while block_lines[-1].rstrip().endswith("\\") and index + 1 < len(lines):
            index += 1
            block_lines.append(lines[index])
        blocks.append((start + 1, "\n".join(block_lines)))
        index += 1

    return blocks


def scope_error(command_group: str, action: str, block: str, source: str) -> str | None:
    has_cloud = bool(re.search(r"--cloud(?:=|\s)", block))
    has_cloud_name = bool(re.search(r"--cloud-name(?:=|\s)", block))
    has_id = bool(re.search(r"--(?:id|service-id|compute-config-id)\b", block))

    if command_group == "cloud":
        if action in {"list", "get-default", "login"}:
            return None
        return None if has_id else "cloud operation must use an immutable --id"

    if command_group == "job":
        if action == "terminate":
            return None if has_id else "job termination must use an immutable --id"
        return None if has_cloud else "job operation must specify --cloud"

    if command_group == "service":
        if action in {"terminate", "archive"} and has_id:
            return None
        return None if has_cloud else "service operation must specify --cloud or immutable --id"

    if command_group == "workspace_v2":
        return (
            None
            if has_cloud or has_id
            else "workspace operation must specify --cloud or immutable --id"
        )

    if command_group == "compute-config":
        if action == "archive":
            return None if has_id else "compute-config archival must use an immutable --id"
        if action == "create":
            if "--config-file" not in block:
                return "compute-config creation must use --config-file"
            if "cloud: ${CLOUD_REF}" not in source:
                return "compute-config YAML must contain the exact cloud reference"
            return None
        return None if has_cloud_name else "compute-config operation must specify --cloud-name"

    return None


def run_self_tests() -> None:
    assert scope_error("job", "submit", "anyscale job submit --cloud exact", "") is None
    assert scope_error("job", "submit", "anyscale job submit", "") is not None
    assert scope_error("job", "terminate", "anyscale job terminate --id prodjob_123", "") is None
    assert scope_error("service", "list", "anyscale service list --cloud exact", "") is None
    assert scope_error("workspace_v2", "list", "anyscale workspace_v2 list", "") is not None
    assert scope_error("compute-config", "get", "anyscale compute-config get", "") is not None
    assert (
        scope_error(
            "compute-config",
            "create",
            "anyscale compute-config create --config-file config.yaml",
            "cloud: ${CLOUD_REF}",
        )
        is None
    )
    assert scope_error("cloud", "verify", "anyscale cloud verify", "") is not None
    assert scope_error("cloud", "verify", "anyscale cloud verify --id cld_123", "") is None


def teardown_order_failures() -> list[str]:
    setup_path = SCRIPTS_DIR / "setup.sh"
    source = setup_path.read_text(encoding="utf-8")
    destroy_case = re.search(r"(?ms)^  destroy\)\n(?P<body>.*?)^    ;;$", source)
    if destroy_case is None:
        return ["scripts/setup.sh: unable to find destroy dispatcher"]

    required_order = [
        "import_untracked_anyscale_resources",
        "drain_anyscale_jobs",
        "assert_no_active_anyscale_services_or_workspaces",
        "terminate_anyscale_system_cluster",
        "archive_anyscale_compute_configs",
        "terraform_cmd destroy -auto-approve",
    ]
    body = destroy_case.group("body")
    cursor = 0
    for command in required_order:
        position = body.find(command, cursor)
        if position == -1:
            return [
                f"scripts/setup.sh: destroy must run {command!r} after the preceding safety gate"
            ]
        cursor = position + len(command)
    return []


def terraform_ownership_failures() -> list[str]:
    source = ANYSCALE_TERRAFORM.read_text(encoding="utf-8")
    setup_source = (SCRIPTS_DIR / "setup.sh").read_text(encoding="utf-8")
    required_contracts = {
        'resource "azapi_resource" "anyscale_cloud"': "Terraform must own the Anyscale cloud parent",
        'resource "azapi_resource" "anyscale_cloud_resource"': "Terraform must own cloudResources/default",
        "parent_id                 = azapi_resource.anyscale_cloud[0].id": "the cloud child must reference its parent",
        '"global.cloudDeploymentId"         = azapi_resource.anyscale_cloud_resource[0].output.cloud_deployment_id': "the extension must reference the Terraform-owned cloud child",
        "azapi_resource.anyscale_cloud_resource,": "the extension must depend on the Terraform-owned cloud child",
        "azurerm_kubernetes_cluster_extension.anyscale_operator,": "the Gateway must depend on the operator extension",
    }
    failures = [
        message for contract, message in required_contracts.items() if contract not in source
    ]
    forbidden_shell_deletes = {
        "az k8s-extension delete": "shell must not delete the Terraform-owned operator extension",
        "az resource delete": "shell must not delete Terraform-owned Anyscale RP resources",
        "az rest --method delete": "shell must not delete Terraform-owned Anyscale RP resources",
        "az deployment group delete": "shell must import, not delete, an existing Terraform-owned ARM deployment",
        "kubectl delete gateway": "shell must not delete the Terraform-owned Gateway",
    }
    failures.extend(
        message for command, message in forbidden_shell_deletes.items() if command in setup_source
    )
    return failures


def main() -> int:
    run_self_tests()
    failures = teardown_order_failures() + terraform_ownership_failures()
    for path in sorted(SCRIPTS_DIR.rglob("*.sh")):
        source = path.read_text(encoding="utf-8")
        for line_number, block in command_blocks(source):
            for match in ANYSCALE_COMMAND.finditer(block):
                error = scope_error(match.group(1), match.group(2), block, source)
                if error is not None:
                    relative = path.relative_to(ROOT)
                    failures.append(f"{relative}:{line_number}: {error}")

    if failures:
        print("Anyscale cloud-scope gate failed:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("Anyscale cloud-scope, Terraform-ownership, and teardown-precondition gates passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
