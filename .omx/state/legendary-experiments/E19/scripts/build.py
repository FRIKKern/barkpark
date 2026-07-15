#!/usr/bin/env python3
"""Build deterministic fail-closed E19 evidence after pre-deployment stop."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from common import CANDIDATE_ID, ROOT, SURFACES, capsules, experiment_root, fixtures, physical_hash, semantic_hash, write_json


BLOCKS = {
    "authenticated_studio": "NO_ISOLATED_DEPLOYMENT_OR_AUTHENTICATED_BROWSER_SESSION; LOGIN_OR_API_AUTH_IS_NOT_ACCEPTED",
    "public_reader": "NO_ISOLATED_DEPLOYED_RECORD_WITH_E16_PROVENANCE; URL_REFLECTION_IS_NOT_ACCEPTED",
    "cli_api": "NO_ISOLATED_DEPLOYED_RECORD_WITH_E16_PROVENANCE; LOCAL_CAPSULE_OR_PRODUCTION_API_IS_NOT_ACCEPTED",
}


def build(root: Path) -> None:
    preflight = json.loads((ROOT / "preflight.json").read_text())
    if preflight["deployment_authorized"]:
        raise SystemExit("E19 BUILD REFUSAL: this fail-closed builder cannot execute an authorized deployment")

    candidate_digest = preflight["candidate_digest"]
    fixture_manifest_digest = physical_hash(experiment_root("E03") / "fixture-manifest.json")
    capsule_rows = capsules()
    fixture_rows = fixtures()

    write_json(root / "deployment-manifest.json", {
        "schema_version": "legendary-e19-deployment-manifest/v1",
        "deployment_id": None,
        "base_url": None,
        "environment": "non-production-required-not-created",
        "candidate_id": CANDIDATE_ID,
        "candidate_digest": candidate_digest,
        "fixture_manifest_digest": fixture_manifest_digest,
        "created_at": None,
        "expires_at": None,
        "teardown_command": None,
        "deployment_created": False,
        "production_mutations": 0,
        "block_reason": preflight["stop_reason"],
    })
    write_json(root / "session-manifest.json", {
        "schema_version": "legendary-e19-session-manifest/v1",
        "deployment_id": None,
        "authenticated_browser_session_established": False,
        "login_surfaces_accepted": 0,
        "api_bearer_substitutions_accepted": 0,
        "secrets_persisted": False,
        "block_reason": BLOCKS["authenticated_studio"],
    })
    write_json(root / "provenance-manifest.json", {
        "schema_version": "legendary-e19-provenance-manifest/v1",
        "candidate_id": CANDIDATE_ID,
        "candidate_digest": candidate_digest,
        "fixture_manifest_digest": fixture_manifest_digest,
        "deployment_id": None,
        "deployed_fixture_records": 0,
        "accepted_responses": 0,
        "provenance_mismatches": 0,
        "proxy_promotions": 0,
        "status": "BLOCKED_BEFORE_DEPLOYMENT",
    })

    attempts: list[dict[str, Any]] = []
    for fixture in fixture_rows:
        fixture_id = fixture["id"]
        capsule = capsule_rows[fixture_id]
        for surface in SURFACES:
            attempt = {
                "schema_version": "legendary-e19-attempt/v1",
                "candidate_id": CANDIDATE_ID,
                "candidate_digest": candidate_digest,
                "candidate_source_sha256": capsule["source_sha256"],
                "candidate_capsule_sha256": semantic_hash(capsule),
                "fixture_id": fixture_id,
                "fixture_kind": capsule["unit_type"],
                "surface": surface,
                "deployment_id": None,
                "capture_timestamp": None,
                "invocation_session": "PREDEPLOYMENT_STOP_NO_REAL_SESSION",
                "attempt_status": "BLOCKED",
                "accepted_capture": False,
                "capture_sha256": None,
                "explicit_error": BLOCKS[surface],
                "silent_blank": False,
                "proxy_derived": False,
                "production_contacted": False,
                "evidence_boundary": "RECONCILED_REAL_CELL_ATTEMPT_RECORD_NOT_A_CAPTURE",
            }
            attempt["attempt_sha256"] = semantic_hash(attempt)
            path = root / "attempts" / surface / f"{fixture_id}.json"
            write_json(path, attempt)
            attempts.append({
                "fixture_id": fixture_id,
                "surface": surface,
                "path": str(path.relative_to(root)),
                "attempt_sha256": physical_hash(path),
                "accepted_capture": False,
            })

    write_json(root / "capture-index.json", {
        "schema_version": "legendary-e19-capture-index/v1",
        "candidate_id": CANDIDATE_ID,
        "candidate_digest": candidate_digest,
        "deployment_id": None,
        "formula": "36 fixtures x 3 required real surfaces = 108 reconciled attempts",
        "attempt_count": len(attempts),
        "accepted_capture_count": 0,
        "missing_cells": 0,
        "duplicate_cells": len(attempts) - len({(row["fixture_id"], row["surface"]) for row in attempts}),
        "proxy_cells": 0,
        "rows": attempts,
    })
    write_json(root / "rollback.json", {
        "schema_version": "legendary-e19-rollback/v1",
        "deployment_id": None,
        "fixture_preimages_accounted": 36,
        "fixture_preimages_expected": 36,
        "fixture_records_created": 0,
        "fixture_records_removed_or_restored": 36,
        "rollback_coverage_percent": 100,
        "deployment_torn_down": True,
        "teardown_mode": "NO_DEPLOYMENT_CREATED_PREDEPLOYMENT_STOP",
        "production_mutations": 0,
        "secrets_persisted": False,
    })
    write_json(root / "hard-gates.json", {
        "schema_version": "legendary-e19-hard-gates/v1",
        "outcomes": {
            "frozen_inputs": "PASS",
            "exact_108_real_captures": "FAIL_0_OF_108",
            "authenticated_studio": "BLOCKED_NO_AUTHENTICATED_BROWSER_SESSION_OR_DEPLOYMENT",
            "public_reader": "BLOCKED_NO_DEPLOYED_CANDIDATE_PROVENANCE",
            "cli_api": "BLOCKED_NO_DEPLOYED_CANDIDATE_PROVENANCE",
            "identical_candidate_digest": "PASS_ATTEMPT_BINDING_ONLY",
            "identical_deployment_id": "FAIL_NO_DEPLOYMENT_CREATED",
            "zero_missing_duplicate_proxy_attempt_cells": "PASS",
            "explicit_errors_zero_silent_blanks": "PASS_ATTEMPT_RECORDS_ONLY",
            "applicable_e03_hard_gates": "BLOCKED_NO_REAL_CAPTURE_EVIDENCE",
            "rollback": "PASS_36_OF_36_NO_DEPLOYMENT_CREATED",
            "teardown": "PASS_NO_DEPLOYMENT_CREATED",
            "no_secret_persistence": "PASS",
            "no_production_mutation": "PASS",
        },
        "verdict": {"quality": "BLOCKED", "action": "REWORK"},
    })
    write_json(root / "result.json", {
        "schema_version": "legendary-e19-result/v1",
        "assignment_id": "E19",
        "candidate_id": CANDIDATE_ID,
        "candidate_digest": candidate_digest,
        "deployment_id": None,
        "counts": {
            "fixtures": 36,
            "surfaces": 3,
            "attempts": 108,
            "accepted_candidate_specific_captures": 0,
            "blocked_cells": 108,
            "missing_cells": 0,
            "duplicate_cells": 0,
            "proxy_cells": 0,
            "silent_blanks": 0,
            "rollback_restored_or_untouched": 36,
        },
        "capability_blocks": [
            "A proven isolated expiring non-production deployment and teardown control were unavailable.",
            "An authenticated Studio browser session was unavailable; login and API-only authentication were not substituted.",
            "No public-reader or CLI/API record could be bound to an isolated deployment carrying the E16 candidate digest.",
        ],
        "evidence": {
            "preflight": "preflight.json",
            "deployment_manifest": "deployment-manifest.json",
            "session_manifest": "session-manifest.json",
            "provenance_manifest": "provenance-manifest.json",
            "capture_index": "capture-index.json",
            "rollback": "rollback.json",
            "hard_gates": "hard-gates.json",
            "validation_command": ".omx/state/legendary-experiments/E19/scripts/replay.sh",
            "expected_output": "E19 REPLAY PASS verdict=BLOCKED captures=0 attempts=108 rollback=36/36",
        },
        "verdict": {
            "quality": "BLOCKED",
            "action": "REWORK",
            "winner_selected": False,
            "pilot_authorized": False,
            "real_surface_gate_passed": False,
        },
    })


def main() -> None:
    build(ROOT)
    print("E19 BUILD PASS verdict=BLOCKED captures=0 attempts=108 rollback=36/36")


if __name__ == "__main__":
    main()
