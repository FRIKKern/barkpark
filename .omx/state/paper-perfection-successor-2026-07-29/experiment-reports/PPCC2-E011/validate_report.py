#!/usr/bin/env python3
"""Validate required PPCC2-E011 report evidence and isolation claims."""

import hashlib
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
REQUIRED_METRICS = {
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


def main():
    report_path = HERE / "report.json"
    report = json.loads(report_path.read_text())
    failures = []
    if report.get("assignment_id") != "PPCC2-E011":
        failures.append("wrong assignment id")
    if report.get("cycle_assignment_id") != "547e48cf-77fb-4968-9d33-ac095efed2e9":
        failures.append("wrong cycle assignment id")
    if report.get("snapshot_digest") != "a79f3db7d32a3c0560e6df97161f594aca1faf60fa495ae45acb41df9ad426e6":
        failures.append("wrong snapshot digest")
    if report.get("receipts_sha256") != "7bad1c6d43d6804498a980da6461b3d2ac926897fcb442c8e9bb13980235c09f":
        failures.append("wrong receipts sha256")
    if report.get("unit_count") != 9 or len(report.get("fixture_results", [])) != 9:
        failures.append("fixture count mismatch")
    if not REQUIRED_METRICS.issubset(report.get("metrics", {})):
        failures.append("required metrics missing")
    if report["metrics"]["observed_failure_rate"].get("hard_failures") != 0:
        failures.append("hard failures are nonzero")
    if report["metrics"]["pilot_gate_pass_rate"].get("applicable") is not False:
        failures.append("pilot incorrectly claimed")
    if not all(
        result.get("hard_gate_pass") for result in report.get("fixture_results", [])
    ):
        failures.append("fixture hard gate failed")
    hostile = report["metrics"]["accessibility"][
        "hostile_missing_field_and_malformed_cases"
    ]
    if hostile.get("attempted") != 6 or hostile.get("failed") != 0:
        failures.append("hostile gate mismatch")
    if not report.get("failures_and_rejected_candidates"):
        failures.append("rejected candidates absent")
    decision = report.get("next_round_decision", {})
    if decision.get("winner_declared") or decision.get("round_5_started"):
        failures.append("round 5 or winner incorrectly claimed")
    attestation = report.get("production_mutation_attestation", {})
    for key in (
        "production_papers_mutated",
        "cyclefleet_mutated",
        "root_task_mutated",
        "wave_paper_mutated",
        "repository_source_mutated",
        "round_5_started",
    ):
        if attestation.get(key) is not False:
            failures.append(key + " attestation is not false")
    if not report.get("unvisited_scope"):
        failures.append("unvisited scope absent")
    delegation = report.get("delegation_compliance", {})
    if delegation.get("subagents_spawned") != 1:
        failures.append("delegation evidence missing")
    digest = hashlib.sha256(report_path.read_bytes()).hexdigest()
    recorded = (HERE / "report.sha256").read_text().split()[0]
    if digest != recorded:
        failures.append("report sha256 mismatch")
    result = {
        "assignment_id": "PPCC2-E011",
        "failure_count": len(failures),
        "failures": failures,
        "report_sha256": digest,
        "status": "PASS" if not failures else "FAIL",
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
