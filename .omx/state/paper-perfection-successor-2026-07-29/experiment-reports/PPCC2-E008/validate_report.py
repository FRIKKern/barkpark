#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPORT = HERE / "report.json"
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


def main() -> int:
    report = json.loads(REPORT.read_text(encoding="utf-8"))
    checks = {
        "assignment": report.get("assignment_id") == "PPCC2-E008",
        "receipt": report.get("assignment_receipt")
        == {
            "assignment_id": "PPCC2-E008",
            "cycle_assignment_id": "8ddaa122-30d5-410d-842b-7c4b21da498a",
            "snapshot_digest": "25ad3ff132fba732942a8259e0f66d51d1d30abfb55c0b4223638c8355eb4176",
            "receipts_sha256": "9ef2205d4acc31e66452b0b7f53c64cdcb9f22c67ea03dca9b7c4bcc5886bf8e",
            "unit_count": 9,
            "worker": "worker-2",
            "canonical_task_id": "2",
        },
        "surfaces": report.get("required_surfaces")
        == ["studio", "tui80", "tui40", "email", "cli_api"],
        "metrics": REQUIRED_METRICS.issubset(report.get("metrics", {})),
        "cases": len(report.get("fixture_results", [])) == 27,
        "candidate_ids": {
            result.get("candidate_id") for result in report.get("fixture_results", [])
        }
        == {"PPCC2-E004", "PPCC2-E005", "PPCC2-E006"},
        "failures_recorded": bool(report.get("failures_and_rejected_candidates")),
        "next_round": bool(report.get("next_round_decision")),
        "unvisited_scope": bool(report.get("unvisited_scope")),
        "commands": report.get("actual_command_output", {}).get("command_count", 0) > 0,
        "delegation": report.get("delegation_compliance", {}).get(
            "subagents_spawned"
        )
        == 1,
        "no_production_mutation": all(
            report.get("production_mutation_attestation", {}).get(key) is False
            for key in (
                "production_papers_mutated",
                "cyclefleet_mutated",
                "root_task_mutated",
                "wave_paper_mutated",
                "repository_source_mutated",
                "round_4_started",
            )
        ),
    }
    status = "PASS" if all(checks.values()) else "FAIL"
    print(
        json.dumps(
            {
                "status": status,
                "checks": checks,
                "report_sha256": hashlib.sha256(REPORT.read_bytes()).hexdigest(),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
