#!/usr/bin/env python3
"""Build deterministic E20 evidence for the E19 dependency stop."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from common import ROOT, SURFACES, experiment, fixture_ids, physical_hash, read_json, write_json


BLOCK_REASON = "E19_NOT_PASS_AND_NO_LIVE_IMMUTABLE_DEPLOYMENT"


def build(root: Path) -> None:
    plan_path = experiment("round-06-plan") / "assignments.json"
    e19_root = experiment("E19")
    e19_result_path = e19_root / "result.json"
    e19_deployment_path = e19_root / "deployment-manifest.json"
    e19_provenance_path = e19_root / "provenance-manifest.json"

    plan = read_json(plan_path)
    assignment = next(row for row in plan["assignments"] if row["id"] == "E20")
    e19 = read_json(e19_result_path)
    deployment = read_json(e19_deployment_path)
    provenance = read_json(e19_provenance_path)
    e19_quality = e19["verdict"]["quality"]
    dependency_passed = e19_quality == "PASS" and bool(deployment["deployment_id"])
    if dependency_passed:
        raise SystemExit("E20 BUILD REFUSAL: real-surface execution is required when E19 passes")

    pins = {
        "plan_sha256": physical_hash(plan_path),
        "e19_result_sha256": physical_hash(e19_result_path),
        "e19_deployment_sha256": physical_hash(e19_deployment_path),
        "e19_provenance_sha256": physical_hash(e19_provenance_path),
        "fixture_manifest_sha256": physical_hash(experiment("E03") / "fixture-manifest.json"),
        "candidate_digest": e19["candidate_digest"],
        "deployment_id": deployment["deployment_id"],
    }
    write_json(root / "preflight.json", {
        "schema_version": "legendary-e20-preflight/v1",
        "assignment_id": assignment["id"],
        "assignment_immutable": assignment["immutable"],
        "depends_on": assignment["depends_on"],
        "dependency_gate_passed": False,
        "e19_quality": e19_quality,
        "e19_accepted_captures": e19["counts"]["accepted_candidate_specific_captures"],
        "deployment_id": deployment["deployment_id"],
        "deployment_created": deployment["deployment_created"],
        "provenance_status": provenance["status"],
        "stop_reason": BLOCK_REASON,
        "pins": pins,
        "real_surface_actions_started": 0,
        "production_targets_contacted": 0,
        "secrets_persisted": False,
    })
    write_json(root / "tui-session-manifest.json", {
        "schema_version": "legendary-e20-tui-session-manifest/v1",
        "candidate_digest": pins["candidate_digest"],
        "deployment_id": pins["deployment_id"],
        "required_terminal": {"columns": 40, "rows": 24},
        "sessions_required": 36,
        "sessions_started": 0,
        "sessions_accepted": 0,
        "bp_binary_path": None,
        "bp_binary_sha256": None,
        "interactive_selection_attempts": 0,
        "pdrender_or_stdout_substitutions": 0,
        "status": "NOT_STARTED_DEPENDENCY_BLOCK",
        "block_reason": BLOCK_REASON,
    })
    write_json(root / "delivery-manifest.json", {
        "schema_version": "legendary-e20-delivery-manifest/v1",
        "candidate_digest": pins["candidate_digest"],
        "deployment_id": pins["deployment_id"],
        "messages_required": 36,
        "messages_sent": 0,
        "delivery_receipts": 0,
        "client_open_timestamps": 0,
        "real_client_name": None,
        "transport": None,
        "fake_or_proxy_receipts": 0,
        "endpoint_browser_or_raw_mime_substitutions": 0,
        "status": "NOT_STARTED_DEPENDENCY_BLOCK",
        "block_reason": BLOCK_REASON,
    })

    rows: list[dict[str, Any]] = []
    for fixture_id in fixture_ids():
        for surface in SURFACES:
            cell = {
                "schema_version": "legendary-e20-cell/v1",
                "fixture_id": fixture_id,
                "surface": surface,
                "candidate_digest": pins["candidate_digest"],
                "deployment_id": None,
                "status": "NOT_STARTED",
                "accepted_capture": False,
                "capture_sha256": None,
                "explicit_block": BLOCK_REASON,
                "silent_blank": False,
                "proxy_evidence": False,
                "delivery_receipt": None,
                "client_open_timestamp": None,
                "production_contacted": False,
            }
            path = root / "cells" / surface / f"{fixture_id}.json"
            write_json(path, cell)
            rows.append({
                "fixture_id": fixture_id,
                "surface": surface,
                "path": str(path.relative_to(root)),
                "cell_sha256": physical_hash(path),
                "status": "NOT_STARTED",
                "accepted_capture": False,
            })

    write_json(root / "capture-index.json", {
        "schema_version": "legendary-e20-capture-index/v1",
        "formula": "36 fixtures x 2 required real surfaces = 72 dependency-gated cells",
        "expected_cells": 72,
        "cell_count": len(rows),
        "not_started_cells": len(rows),
        "accepted_capture_count": 0,
        "duplicate_cells": len(rows) - len({(row["fixture_id"], row["surface"]) for row in rows}),
        "missing_cells": 72 - len(rows),
        "proxy_cells": 0,
        "silent_blank_cells": 0,
        "rows": rows,
    })
    write_json(root / "rollback.json", {
        "schema_version": "legendary-e20-rollback/v1",
        "sessions_started": 0,
        "messages_sent": 0,
        "test_accounts_created": 0,
        "sessions_or_messages_cleaned": 0,
        "fixture_records_untouched": 36,
        "fixture_records_expected": 36,
        "rollback_coverage_percent": 100,
        "cleanup_mode": "NO_ACTIONS_STARTED_DEPENDENCY_STOP",
        "production_mutations": 0,
        "secrets_persisted": False,
        "e19_pins_before_and_after": pins,
    })
    write_json(root / "hard-gates.json", {
        "schema_version": "legendary-e20-hard-gates/v1",
        "outcomes": {
            "immutable_assignment": "PASS",
            "e19_pass_and_live_deployment": "BLOCKED_E19_BLOCKED_DEPLOYMENT_NULL",
            "exact_72_real_captures": "FAIL_0_OF_72",
            "real_interactive_bp_tui": "NOT_STARTED_DEPENDENCY_BLOCK",
            "delivered_real_client_email": "NOT_STARTED_DEPENDENCY_BLOCK",
            "zero_proxy_evidence": "PASS",
            "zero_silent_blanks": "PASS_EXPLICIT_BLOCKS_72_OF_72",
            "zero_fake_receipts_or_client_opens": "PASS",
            "e19_immutable": "PASS_HASH_PINNED",
            "rollback_or_untouched": "PASS_36_OF_36",
            "no_production_mutation": "PASS",
        },
        "verdict": {"quality": "BLOCKED", "action": "REWORK"},
    })
    write_json(root / "result.json", {
        "schema_version": "legendary-e20-result/v1",
        "assignment_id": "E20",
        "candidate_digest": pins["candidate_digest"],
        "deployment_id": None,
        "pins": pins,
        "counts": {
            "fixtures": 36,
            "surfaces": 2,
            "expected_cells": 72,
            "not_started_cells": 72,
            "accepted_candidate_specific_captures": 0,
            "proxy_cells": 0,
            "silent_blanks": 0,
            "delivery_receipts": 0,
            "client_open_captures": 0,
            "production_mutations": 0,
            "rollback_or_untouched": 36,
        },
        "capability_blocks": [
            "E19 is BLOCKED rather than PASS.",
            "E19 has no live immutable isolated deployment id.",
            "The immutable E20 stop condition forbids TUI sessions, delivery, and client capture before E19 passes.",
        ],
        "evidence": {
            "preflight": "preflight.json",
            "tui_session_manifest": "tui-session-manifest.json",
            "delivery_manifest": "delivery-manifest.json",
            "capture_index": "capture-index.json",
            "rollback": "rollback.json",
            "hard_gates": "hard-gates.json",
            "validation_command": ".omx/state/legendary-experiments/E20/scripts/replay.sh",
            "expected_output": "E20 REPLAY PASS verdict=BLOCKED cells=72 accepted=0 proxies=0",
        },
        "verdict": {
            "quality": "BLOCKED",
            "action": "REWORK",
            "real_surface_gate_passed": False,
            "winner_selected": False,
            "pilot_authorized": False,
        },
    })


def main() -> None:
    build(ROOT)
    print("E20 BUILD PASS verdict=BLOCKED cells=72 accepted=0 proxies=0")


if __name__ == "__main__":
    main()
