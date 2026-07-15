#!/usr/bin/env python3
"""Verify E05 evidence and emit the frozen-threshold scorecard/result."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from adapter import SCHEMA_VERSION, semantic_hash


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
OUTPUTS = ROOT / "outputs"
EXPECTED_INPUT_HASHES = {
    "e03-fixture-manifest.json": "0ab24d0a38f9d8db97073accaea37f02786d9c47f7dac3471e858907d5c308df",
    "e03-thresholds.json": "4117e563cb8d261b3256823fc90f16fb0e3d57a51fa84ab8b0a609d3684ecd6b",
    "e03-candidate-rubric.json": "3805ed5afb1ed76c22ba2144aefaf2d5c5e73508fb8f4170d9441e3400d952d4",
    "e03-failure-taxonomy.json": "29fbb60a099ff6607efd87716887f592e2443498c5b65f2b87317ba3e1807ce9",
    "source-documents.json": "803ea48c241c50e9018470837a02071980298b102d7d035182cc99c9e7338cbf",
}
REQUIRED_RESULT_FIELDS = {
    "assignment_id", "round", "candidate_ids", "input_hashes", "fixture_manifest_path",
    "fixture_manifest_sha256", "commands_or_probes", "observed_facts", "inferences",
    "recommendations", "unresolved_unknowns", "surface_matrix", "threshold_results",
    "evidence_paths", "validation", "risks", "stop_condition", "verdict",
}


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E05 VERIFY FAIL: {message}")


def main() -> None:
    observed_inputs = {name: physical_hash(FIXTURES / name) for name in EXPECTED_INPUT_HASHES}
    require(observed_inputs == EXPECTED_INPUT_HASHES, "frozen E03 input hashes drifted")
    manifest = load_json(FIXTURES / "manifest.json")
    require(manifest["counts"] == {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36}, "fixture counts")
    require(len(manifest["items"]) == len({row["id"] for row in manifest["items"]}) == 36, "fixture uniqueness")

    envelopes = [json.loads(line) for line in (OUTPUTS / "envelopes.jsonl").read_text().splitlines() if line]
    rollback = load_json(OUTPUTS / "rollback-manifest.json")["rows"]
    quarantine = load_json(OUTPUTS / "quarantine.json")["rows"]
    matrix = load_json(OUTPUTS / "surface-matrix.json")
    committed_timing = load_json(OUTPUTS / "timing.json")
    require(len(envelopes) == 36, "envelope count")
    require(all(row["schema_version"] == SCHEMA_VERSION for row in envelopes), "envelope schema")
    require(all(row["authority"] == {"source_of_truth": "source", "derived_views_authoritative": False, "single_truth_count": 1} for row in envelopes), "single source of truth")
    require(all(semantic_hash(row["source"]) == row["provenance"]["source_semantic_sha256"] for row in envelopes), "source preservation")
    require(
        all(
            row["status"] == "PASS"
            and row["idempotence_status"] == "PASS"
            and row["rollback_status"] == "PASS"
            and row["first_envelope_sha256"] == row["second_envelope_sha256"]
            and not row["residue_keys"]
            for row in rollback
        ),
        "rollback/idempotence",
    )
    require(all(row["rollback_status"] == "PASS" for row in quarantine), "quarantine rollback")
    task_rows = [row for row in envelopes if row["unit_type"] == "task"]
    require(len(task_rows) == 18, "task envelope count")
    require(all(row["annotation"]["authority"] == "advisory_only" and row["annotation"]["may_mutate_source"] is False for row in task_rows), "task annotation boundary")
    require(matrix["fixture_count"] == 36 and matrix["surface_count"] == 5 and matrix["cell_count"] == 180, "surface matrix counts")
    require(matrix["status_counts"] == {"PASS": 108, "BLOCKED": 72, "FAIL": 0}, "surface statuses")
    require(all(row["nonblank_or_explicit_error"] for row in matrix["rows"]), "silent blank output")
    require(not any(row["status"] == "PASS" and row["surface"] in {"Studio", "email"} for row in matrix["rows"]), "blocked surface promoted to PASS")
    require(
        committed_timing["schema_version"] == "legendary-e05-timing/v1"
        and committed_timing["fixture_count"] == 36
        and committed_timing["under_60_minutes"] is True,
        "committed timing evidence",
    )

    frozen_thresholds = load_json(FIXTURES / "e03-thresholds.json")["thresholds"]
    threshold_results = {
        "surface_exercise": {"status": "BLOCKED", "evidence": "72/180 cells blocked: authenticated Studio and real-client email unavailable"},
        "reader_visibility": {"status": "PARTIAL", "evidence": "180/180 scratch outputs nonblank or explicit supported error; two real surfaces blocked"},
        "structural_completeness": {"status": "PASS", "evidence": "36/36 full source objects preserved inside envelope"},
        "schema_validity": {"status": "PASS", "evidence": "36/36 candidate envelopes validate; malformed source is explicit-error quarantined"},
        "accessibility": {"status": "PARTIAL", "evidence": "deterministic scratch reading order; authenticated Studio and real-client email untested"},
        "width_overflow": {"status": "PASS", "evidence": "20-column TUI and 72-column email scratch wrapping preserves long tokens"},
        "authored_content_preservation": {"status": "PASS", "evidence": "36/36 source semantic hashes match provenance and rollback pre-image"},
        "idempotence": {"status": "PASS", "evidence": "36/36 second envelope applications are semantic-hash identical"},
        "rollback": {"status": "PASS", "evidence": f"36/36 restored without residue; {len(quarantine)}/{len(quarantine)} quarantines restored"},
        "render_test_gate": {"status": "PARTIAL", "evidence": "all isolated gates pass; real Studio/email gates blocked"},
        "pilot_failure_rate": {"status": "NOT_APPLICABLE_ROUND_2", "evidence": "candidate divergence round, not pilot"},
        "capacity_rule": {"status": "NOT_APPLICABLE_ROUND_2", "evidence": "capacity is frozen only after Round 5 pilot"},
        "build_formula": {"status": "NOT_APPLICABLE_ROUND_2", "evidence": "requires proven pilot capacity"},
    }
    require(set(threshold_results) == set(frozen_thresholds), "all frozen thresholds represented exactly once")
    scorecard = {
        "schema_version": "legendary-e05-threshold-scorecard/v1",
        "assignment_id": "E05",
        "candidate_id": "candidate-preservation-envelope",
        "frozen_thresholds_sha256": EXPECTED_INPUT_HASHES["e03-thresholds.json"],
        "threshold_results": threshold_results,
        "hard_gate_summary": {"PASS": 6, "PARTIAL": 3, "BLOCKED": 1, "NOT_APPLICABLE_ROUND_2": 3},
        "candidate_stop_condition_triggered": False,
        "phase_gate_open": True,
    }
    write_json(OUTPUTS / "scorecard.json", scorecard)

    artifact_paths = [
        FIXTURES / "manifest.json", OUTPUTS / "envelopes.jsonl", OUTPUTS / "rollback-manifest.json",
        OUTPUTS / "quarantine.json", OUTPUTS / "surface-matrix.json", OUTPUTS / "scorecard.json",
        OUTPUTS / "timing.json",
    ]
    artifact_hashes = {str(path.relative_to(ROOT)): physical_hash(path) for path in artifact_paths}
    write_json(OUTPUTS / "hashes.json", {"schema_version": "legendary-e05-artifact-hashes/v1", "files": artifact_hashes})
    candidate_hash = semantic_hash(envelopes)
    fixture_manifest_hash = physical_hash(FIXTURES / "manifest.json")
    result = {
        "schema_version": "legendary-e05-result/v1",
        "assignment_id": "E05",
        "round": 2,
        "candidate_ids": ["candidate-preservation-envelope"],
        "input_hashes": observed_inputs,
        "fixture_manifest_path": "fixtures/manifest.json",
        "fixture_manifest_sha256": fixture_manifest_hash,
        "commands_or_probes": [
            "python3 scripts/build_fixture_manifest.py",
            "python3 scripts/build_candidate.py",
            "python3 scripts/test_adapter.py",
            "python3 scripts/verify.py",
            "scripts/replay.sh",
        ],
        "observed_facts": [
            "36 exact E03 fixtures produced 36 deterministic preservation envelopes and 180 surface cells.",
            f"Candidate semantic sha256 is {candidate_hash}.",
            f"{len(quarantine)} malformed/empty authoritative sources emitted explicit supported errors and were quarantined.",
            "All original source objects remain the sole authority; all reader views are derived.",
            "Authenticated Studio and real-client email evidence remain unavailable and BLOCKED.",
        ],
        "inferences": [
            "The adapter-first shape is mechanically reversible and preserves authored source better than eager normalization for these fixtures.",
            "Scratch rendering cannot establish real Studio or email behavior.",
        ],
        "recommendations": [
            "Carry E05 into Round 3 hostile-reader testing only after the leader compares all Round-2 candidates.",
            "Provide authenticated Studio and real-client email harnesses before any winner decision.",
        ],
        "unresolved_unknowns": [
            "Authenticated Studio content behavior for the envelope.",
            "Real-client email rendering, clipping, and accessibility behavior.",
        ],
        "surface_matrix": {"path": "outputs/surface-matrix.json", "sha256": artifact_hashes["outputs/surface-matrix.json"], "status_counts": matrix["status_counts"]},
        "threshold_results": threshold_results,
        "evidence_paths": sorted(artifact_hashes) + ["fixtures/e03-failure-taxonomy.json", "fixtures/e03-candidate-rubric.json"],
        "validation": {"command": "scripts/replay.sh", "expected_output": "E05 REPLAY PASS", "status": "PASS"},
        "risks": [
            "Candidate has no real authenticated Studio evidence.",
            "Candidate has no real-client email evidence.",
            "Generic PortableDoc text extraction is a scratch compatibility view, not a product renderer.",
        ],
        "stop_condition": {
            "contract": "Reject if the envelope creates multiple competing truths, masks malformed source, or cannot be removed without residue.",
            "outcome": "NOT_TRIGGERED",
            "evidence": "36/36 single-authority envelopes; malformed sources explicit-error quarantined; 36/36 residue-free rollback.",
        },
        "capability_blocks": ["authenticated Studio content proof unavailable", "real-client email proof unavailable"],
        "counts": {"fixtures": 36, "papers": 12, "tasks": 18, "adversarial": 6, "surface_cells": 180, "surface_pass": 108, "surface_blocked": 72, "surface_fail": 0, "quarantined": len(quarantine)},
        "candidate_semantic_sha256": candidate_hash,
        "artifact_hashes": artifact_hashes,
        "timing": committed_timing,
        "timing_policy": {
            "committed": "outputs/timing.json preserves the accepted measured evidence and is immutable on ordinary replay",
            "volatile": "ordinary replay writes its current observation to $E05_VOLATILE_TIMING_PATH or the system temporary directory",
            "refresh": "set E05_REFRESH_TIMING=1 only for an intentional evidence refresh",
        },
        "verdict": {"quality": "PARTIAL", "action": "REWORK", "self_selected_as_winner": False},
    }
    require(REQUIRED_RESULT_FIELDS <= set(result), "required result fields")
    write_json(ROOT / "result.json", result)
    print(f"E05 VERIFY PASS fixtures=36 cells=180 rollback=36/36 candidate_sha256={candidate_hash} verdict=PARTIAL/REWORK")


if __name__ == "__main__":
    main()
