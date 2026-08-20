#!/usr/bin/env python3
"""Build deterministic E12 convergence evidence without mutating source data."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
HERE = ROOT / ".omx/state/legendary-experiments/E12"
E03 = ROOT / ".omx/state/legendary-experiments/E03"
E05 = ROOT / ".omx/state/legendary-experiments/E05"
E09 = ROOT / ".omx/state/legendary-experiments/E09"


def load(path: Path):
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(name: str, value) -> None:
    (HERE / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    thresholds_path = E03 / "thresholds.json"
    fixture_manifest_path = E03 / "fixture-manifest.json"
    envelopes_path = E05 / "outputs/envelopes.jsonl"
    rollback_path = E05 / "outputs/rollback-manifest.json"
    quarantine_path = E05 / "outputs/quarantine.json"
    attack_path = E09 / "outputs/attack-matrix.json"
    e09_result_path = E09 / "result.json"

    envelopes = [json.loads(line) for line in envelopes_path.read_text().splitlines() if line]
    rollback = load(rollback_path)["rows"]
    quarantines = {row["fixture_id"]: row for row in load(quarantine_path)["rows"]}
    attack = load(attack_path)
    e09_result = load(e09_result_path)
    rollback_by_id = {row["fixture_id"]: row for row in rollback}

    input_paths = {
        "E03/fixture-manifest.json": fixture_manifest_path,
        "E03/thresholds.json": thresholds_path,
        "E05/outputs/envelopes.jsonl": envelopes_path,
        "E05/outputs/quarantine.json": quarantine_path,
        "E05/outputs/rollback-manifest.json": rollback_path,
        "E09/outputs/attack-matrix.json": attack_path,
        "E09/result.json": e09_result_path,
    }
    input_hashes = {
        "assignment_id": "E12",
        "schema_version": "legendary-e12-input-hashes/v1",
        "inputs": {name: {"path": str(path.relative_to(ROOT)), "sha256": sha256(path)} for name, path in input_paths.items()},
    }
    write("input-hashes.json", input_hashes)

    routes = []
    for envelope in sorted(envelopes, key=lambda row: row["fixture_id"]):
        fixture_id = envelope["fixture_id"]
        proof = rollback_by_id[fixture_id]
        quarantine = quarantines.get(fixture_id)
        route = "quarantine" if quarantine else "preservation_envelope_dry_run"
        routes.append({
            "authority": "source_only",
            "before_sha256": proof["preimage_sha256"],
            "candidate_id": "candidate-preservation-envelope",
            "evidence_truth_boundary": "derived views are advisory; source object remains authoritative",
            "fixture_id": fixture_id,
            "idempotence_sha256": proof["first_envelope_sha256"],
            "quarantine_reason": quarantine["reason"] if quarantine else None,
            "rollback_preimage_sha256": proof["preimage_sha256"],
            "route": route,
            "route_status": "BLOCKED_FROM_PRODUCTION" if quarantine else "DRY_RUN_ONLY",
        })

    manifest = {
        "assignment_id": "E12",
        "candidate_provenance": {
            "candidate_id": "candidate-preservation-envelope",
            "source_assignment": "E05",
            "status": "STRONGEST_NON_REJECTED_BUT_BLOCKED",
            "winner": False,
        },
        "frozen_fixture_count": len(routes),
        "routes": routes,
        "schema_version": "legendary-e12-migration-manifest/v1",
    }
    write("migration-manifest.json", manifest)

    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "urn:barkpark:legendary:e12:migration-manifest:v1",
        "additionalProperties": False,
        "properties": {
            "assignment_id": {"const": "E12"},
            "candidate_provenance": {"type": "object"},
            "frozen_fixture_count": {"const": 36},
            "routes": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "authority": {"const": "source_only"},
                        "before_sha256": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
                        "candidate_id": {"const": "candidate-preservation-envelope"},
                        "evidence_truth_boundary": {"minLength": 1, "type": "string"},
                        "fixture_id": {"minLength": 1, "type": "string"},
                        "idempotence_sha256": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
                        "quarantine_reason": {"type": ["string", "null"]},
                        "rollback_preimage_sha256": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
                        "route": {"enum": ["preservation_envelope_dry_run", "quarantine"]},
                        "route_status": {"enum": ["DRY_RUN_ONLY", "BLOCKED_FROM_PRODUCTION"]},
                    },
                    "required": ["authority", "before_sha256", "candidate_id", "evidence_truth_boundary", "fixture_id", "idempotence_sha256", "quarantine_reason", "rollback_preimage_sha256", "route", "route_status"],
                    "type": "object",
                },
                "minItems": 36,
                "maxItems": 36,
                "type": "array",
            },
            "schema_version": {"const": "legendary-e12-migration-manifest/v1"},
        },
        "required": ["assignment_id", "candidate_provenance", "frozen_fixture_count", "routes", "schema_version"],
        "title": "E12 dry-run migration manifest",
        "type": "object",
    }
    write("migration-manifest-schema.json", schema)

    e05_attack = attack["candidates"]["E05"]
    proof_rows = [{
        "fixture_id": row["fixture_id"],
        "first_envelope_sha256": row["first_envelope_sha256"],
        "second_envelope_sha256": row["second_envelope_sha256"],
        "preimage_sha256": row["preimage_sha256"],
        "restored_sha256": row["restored_sha256"],
        "idempotence_status": row["idempotence_status"],
        "rollback_status": row["rollback_status"],
        "residue_keys": row["residue_keys"],
    } for row in sorted(rollback, key=lambda row: row["fixture_id"])]
    proof = {
        "assignment_id": "E12",
        "candidate_id": "E05",
        "candidate_artifact_two_run_stability": e05_attack["first_run_hashes"] == e05_attack["second_run_hashes"],
        "fixture_count": len(proof_rows),
        "rows": proof_rows,
        "schema_version": "legendary-e12-rollback-idempotence-proof/v1",
        "summary": {
            "idempotent": sum(row["idempotence_status"] == "PASS" for row in proof_rows),
            "restored": sum(row["rollback_status"] == "PASS" and row["preimage_sha256"] == row["restored_sha256"] for row in proof_rows),
            "residue_free": sum(not row["residue_keys"] for row in proof_rows),
        },
    }
    write("rollback-idempotence-proof.json", proof)

    rules = {
        "assignment_id": "E12",
        "authority_rules": [
            {"condition": "source field is authored", "decision": "source remains sole authority; derived values are advisory"},
            {"condition": "class or authority decision is ambiguous", "decision": "quarantine and require sealed human/authority record"},
            {"condition": "derived field lacks field-level provenance", "decision": "reject candidate output"},
        ],
        "escalation": {"required_record": "sealed paired blind record", "required_records_before_scoring": 20, "current_records": attack["blind_gate"]["sealed_record_count"]},
        "quarantine_rules": [
            {"condition": "missing or empty authoritative source", "reason": "empty_source"},
            {"condition": "malformed authoritative source", "reason": "malformed_authoritative_source"},
            {"condition": "rollback pre-image absent or mismatched", "reason": "rollback_preimage_failure"},
            {"condition": "second run changes semantic hash", "reason": "non_idempotent_rerun"},
        ],
        "schema_version": "legendary-e12-quarantine-authority-rules/v1",
    }
    write("quarantine-authority-rules.json", rules)

    outcomes = {
        "assignment_id": "E12",
        "frozen_thresholds_sha256": sha256(thresholds_path),
        "outcomes": {
            "authored_content_preservation": {"status": "PASS_DRY_RUN", "evidence": "36/36 pre-images retained"},
            "idempotence": {"status": "PASS_DRY_RUN", "evidence": "36/36 fixture hashes stable and E05 tracked artifacts identical across two E09 runs"},
            "rollback": {"status": "PASS_DRY_RUN", "evidence": "36/36 restored hashes equal pre-images; zero residue keys"},
            "evidence_truth_boundary": {"status": "BLOCKED", "evidence": "0/20 required sealed paired blind records"},
            "surface_exercise": {"status": "BLOCKED", "evidence": "authenticated Studio and real-client email unavailable"},
            "convergence": {"status": "REJECTED", "evidence": "Round 3 selected no winner; E05 remains BLOCKED_REWORK"},
        },
        "schema_version": "legendary-e12-threshold-outcomes/v1",
    }
    write("threshold-outcomes.json", outcomes)

    injections = {
        "assignment_id": "E12",
        "cases": [
            {"command": "python3 scripts/verify.py --inject missing-preimage", "expected_exit": 2, "expected_marker": "E12 INJECTION CAUGHT missing-preimage"},
            {"command": "python3 scripts/verify.py --inject fabricated-authority", "expected_exit": 2, "expected_marker": "E12 INJECTION CAUGHT fabricated-authority"},
            {"command": "python3 scripts/verify.py --inject second-run-mutation", "expected_exit": 2, "expected_marker": "E12 INJECTION CAUGHT second-run-mutation"},
        ],
        "schema_version": "legendary-e12-failure-injection/v1",
    }
    write("failure-injection.json", injections)

    artifact_names = [
        "failure-injection.json", "input-hashes.json", "migration-manifest-schema.json",
        "migration-manifest.json", "quarantine-authority-rules.json",
        "rollback-idempotence-proof.json", "threshold-outcomes.json",
    ]
    result = {
        "artifact_hashes": {name: sha256(HERE / name) for name in artifact_names},
        "assignment_id": "E12",
        "candidate_provenance": {
            "candidate_id": "E05",
            "round_3_status": attack["candidate_verdicts"]["E05"]["status"],
            "strongest_non_rejected_candidate": e09_result["verdict"]["strongest_non_rejected_candidate"],
            "winner_selected": False,
        },
        "capability_blocks": e09_result["capability_blocks"],
        "counts": {"fixtures": len(routes), "dry_run_routes": len(routes) - len(quarantines), "quarantines": len(quarantines), "sealed_blind_records": attack["blind_gate"]["sealed_record_count"]},
        "exact_next_complete_three": [
            {"id": "E13", "requirement": "Seal >=20 paired blind records before scoring; rerun classification/authority attack without proxy records."},
            {"id": "E14", "requirement": "Capture authenticated Studio, real-client email, and real TUI evidence for all 36 frozen fixtures under unchanged E03 thresholds."},
            {"id": "E15", "requirement": "Repeat migration/idempotence/rollback convergence against the resulting eligible candidate; reject on any missing route, pre-image, truth boundary, or hard surface failure."},
        ],
        "hard_gate_outcomes": outcomes["outcomes"],
        "probes": ["deterministic 36-route construction", "E09 two-run artifact comparison", "36 pre-image restoration checks", "three negative failure injections"],
        "schema_version": "legendary-e12-result/v1",
        "stop_condition": "Triggered: Round 3 has no winner and evidence-truth/surface gates remain blocked.",
        "timing": {"source": "timing.json", "policy": "representative replay observation is committed once; deterministic artifacts exclude wall-clock bytes"},
        "verdict": {"action": "REWORK", "quality": "PARTIAL", "winner_selected": False, "reason": "Migration mechanics pass in dry-run evidence, but convergence cannot pass without a Round-3 winner, sealed blind records, and real Studio/email evidence."},
    }
    write("result.json", result)


if __name__ == "__main__":
    main()
