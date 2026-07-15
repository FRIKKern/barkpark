#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from common import CANDIDATE_DIGEST, CANDIDATE_ID, ROOT, SURFACES, fixture_ids, physical_hash, read_json, write_json


def build(root: Path = ROOT) -> None:
    preflight = read_json(ROOT / "preflight.json")
    if preflight["deployment_authorized"]:
        raise SystemExit("E22 BLOCKED BUILD REFUSED: authorized runtime must use real provision/capture/teardown")
    provenance = {
        "schema_version": "legendary-e22-provenance/v1", "assignment_id": "E22",
        "candidate_id": CANDIDATE_ID, "candidate_digest": CANDIDATE_DIGEST,
        "fixture_manifest_sha256": preflight["input_hashes"]["E03/fixture-manifest.json"]["actual_sha256"],
        "capsules_sha256": preflight["input_hashes"]["E16/output/capsules.jsonl"]["actual_sha256"],
        "fixtures": fixture_ids(), "deployment_id": None,
    }
    deployment = {
        "schema_version": "legendary-e22-deployment/v1", "assignment_id": "E22", "deployment_id": None,
        "status": "NOT_CREATED", "isolated": False, "production_mutations": 0,
        "ttl_minutes": preflight["ttl_minutes"], "expires_at": None,
        "teardown_authority_proven": False, "runtime_fingerprints": preflight["runtime_fingerprints"],
        "secret_values_persisted": False, "blockers": preflight["stop_reasons"],
    }
    session = {
        "schema_version": "legendary-e22-session/v1", "assignment_id": "E22", "deployment_id": None,
        "studio_authenticated": False, "studio_anonymous": False, "studio_redirected": False,
        "login_ticket_minted": False, "login_ticket_persisted": False,
        "public_reader_session": "NOT_ATTEMPTED", "cli_invocations": 0,
        "blocker": "AUTHORIZED_ISOLATED_RUNTIME_VALUES_UNAVAILABLE",
    }
    rows = []
    for fixture in fixture_ids():
        for surface in SURFACES:
            attempt = {
                "schema_version": "legendary-e22-capture-attempt/v1", "fixture_id": fixture, "surface": surface,
                "candidate_digest": CANDIDATE_DIGEST, "deployment_id": None, "attempt_status": "BLOCKED",
                "accepted_capture": False, "capture_sha256": None, "screenshot_sha256": None,
                "transcript_sha256": None, "semantic_sha256": None, "proxy_derived": False,
                "url_reflected": False, "silent_blank": False, "production_contacted": False,
                "explicit_error": "AUTHORIZED_ISOLATED_RUNTIME_VALUES_UNAVAILABLE",
            }
            rel = Path("attempts") / surface / f"{fixture.replace('/', '_')}.json"
            write_json(root / rel, attempt)
            rows.append({"fixture_id": fixture, "surface": surface, "path": str(rel), "attempt_sha256": physical_hash(root / rel), "accepted_capture": False})
    rows.sort(key=lambda r: (r["fixture_id"], r["surface"]))
    index = {
        "schema_version": "legendary-e22-capture-index/v1", "assignment_id": "E22", "rows": rows,
        "attempt_count": 108, "accepted_capture_count": 0, "blocked_cells": 108,
        "missing_cells": 0, "duplicate_cells": 0, "blank_cells": 0, "proxy_cells": 0, "url_reflection_cells": 0,
    }
    rollback = {
        "schema_version": "legendary-e22-rollback/v1", "assignment_id": "E22", "deployment_id": None,
        "no_deployment_created": True, "fixture_records_removed_or_untouched": 36,
        "rollback_coverage_percent": 100, "credentials_or_tickets_revoked_or_unminted": True,
        "deployment_unavailable": True, "zero_residual_records": True, "production_mutations": 0,
        "secrets_persisted": False, "teardown_status": "NOT_REQUIRED_PREPROVISION_BLOCK",
    }
    result = {
        "schema_version": "legendary-e22-result/v1", "assignment_id": "E22",
        "candidate_id": CANDIDATE_ID, "candidate_digest": CANDIDATE_DIGEST, "deployment_id": None,
        "counts": {"fixtures": 36, "surfaces": 3, "attempts": 108, "accepted_captures": 0, "blocked_cells": 108, "rollback_restored_or_untouched": 36},
        "verdict": {"quality": "BLOCKED", "action": "REWORK", "real_surface_gate_passed": False, "winner_selected": False, "pilot_authorized": False},
        "remaining_external_authority": "Authorized provably non-production isolated base URL/database plus short-lived admin token.",
    }
    for name, value in (("provenance-manifest.json", provenance), ("deployment-manifest.json", deployment), ("session-manifest.json", session), ("capture-index.json", index), ("rollback.json", rollback), ("result.json", result)):
        write_json(root / name, value)


def main() -> None:
    p = argparse.ArgumentParser(); p.add_argument("--output", type=Path, default=ROOT); args = p.parse_args()
    build(args.output)
    print("E22 BLOCKED EVIDENCE BUILT attempts=108 captures=0 rollback=36/36")


if __name__ == "__main__": main()
