#!/usr/bin/env python3
"""Fail-closed structural validator for the PPCC2-E006 report."""

import argparse
import hashlib
import json
from pathlib import Path


METRICS = {
    "portable_doc_schema_validity",
    "studio_structural_completeness",
    "tui_width",
    "email_safety",
    "cli_api_round_trip",
    "accessibility",
    "content_preservation",
    "pilot_gate_pass_rate",
    "observed_failure_rate",
    "batch_capacity",
    "rollback",
}
MUTATION_FLAGS = {
    "production_papers_mutated",
    "cyclefleet_mutated",
    "root_task_mutated",
    "wave_paper_mutated",
    "repository_source_mutated",
    "round_3_started",
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding="utf-8"))

    require(report.get("assignment_id") == "PPCC2-E006", "assignment id")
    require(report.get("canonical_task_id") == "3", "canonical task id")
    require(report.get("worker") == "worker-3", "worker")
    require(report.get("agent_type") == "legendary-experimenter", "typed role")
    require(report.get("round") == 2 and report.get("round_key") == "diverge", "round")
    require(len(report.get("fixture_ids", [])) == 9, "exact fixture count")
    require(
        report.get("required_surfaces")
        == ["studio", "tui80", "tui40", "email", "cli_api"],
        "exact required surfaces",
    )
    receipt = report.get("assignment_receipt", {})
    require(
        receipt.get("cycle_assignment_id")
        == "a7de4476-3fdb-49ad-86ac-962d097c47c8",
        "cycle assignment receipt",
    )
    require(
        receipt.get("snapshot_digest")
        == "fe19b00abb09b07b3fd19d63b41f89e447e1b102ffb3b45ed0907cf607091f50",
        "snapshot digest",
    )
    require(receipt.get("unit_count") == 9, "receipt unit count")
    require(set(report.get("metrics", {})) >= METRICS, "required metrics")
    require(len(report.get("fixture_results", [])) == 9, "fixture results")
    require(
        all(row.get("hard_gate_pass") for row in report["fixture_results"]),
        "all fixture hard gates",
    )
    require(report.get("actual_command_outputs"), "actual command output")
    require(report.get("personal_attestation"), "personal attestation")
    require(report.get("failures_and_rejected_candidates"), "failure/rejection record")
    require(report.get("unvisited_scope"), "unvisited scope")
    require(
        report.get("next_round_decision", {}).get("round_3_started") is False,
        "Round 3 must not start",
    )
    mutation = report.get("production_mutation_attestation", {})
    require(
        all(mutation.get(flag) is False for flag in MUTATION_FLAGS),
        "all mutation flags false",
    )
    delegation = report.get("delegation_compliance", {})
    require(delegation.get("subagents_spawned") == 1, "required review probe")
    require(
        delegation.get("child_thread_id") == "/root/ppcc2_e006_review_probe",
        "review probe identity",
    )

    runnable = report.get("runnable_artifact", {})
    for relative in runnable.get("entrypoints", []):
        require((args.report.parent / relative).is_file(), "missing entrypoint " + relative)

    manifest_path = args.report.parent / report["artifact_manifest"]["path"]
    require(manifest_path.is_file(), "artifact manifest")
    require(
        sha256(manifest_path) == report["artifact_manifest"]["sha256"],
        "artifact manifest digest",
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(len(manifest.get("files", [])) >= 65, "artifact inventory size")
    for row in manifest["files"]:
        path = args.report.parent / row["path"]
        require(path.is_file(), "missing artifact " + row["path"])
        require(path.stat().st_size == row["bytes"], "artifact size " + row["path"])
        require(sha256(path) == row["sha256"], "artifact hash " + row["path"])

    print(
        json.dumps(
            {
                "status": "PASS",
                "assignment_id": "PPCC2-E006",
                "fixtures": 9,
                "surfaces": 5,
                "metrics": len(METRICS),
                "artifact_files": len(manifest["files"]),
                "all_mutation_flags_false": True,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
