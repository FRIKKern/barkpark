#!/usr/bin/env python3
"""Build the deterministic E10 fail-closed convergence evidence packet."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


E10 = Path(__file__).resolve().parents[1]
EXPERIMENTS = E10.parent


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def write_json(root: Path, relative: str, value: object) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value))


def source_ref(relative: str) -> dict:
    path = EXPERIMENTS / relative
    return {"path": f"../{relative}", "sha256": digest(path)}


def build(output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "frozen").mkdir(exist_ok=True)

    e03_result = load(EXPERIMENTS / "E03/result.json")
    e05_result = load(EXPERIMENTS / "E05/result.json")
    e08_result = load(EXPERIMENTS / "E08/result.json")
    e08_rejections = load(EXPERIMENTS / "E08/rejection-evidence.json")
    e09_result = load(EXPERIMENTS / "E09/result.json")
    e09_attack = load(EXPERIMENTS / "E09/outputs/attack-matrix.json")

    frozen_inputs = {
        "candidate-rubric.json": EXPERIMENTS / "E03/candidate-rubric.json",
        "thresholds.json": EXPERIMENTS / "E03/thresholds.json",
    }
    for name, source in frozen_inputs.items():
        shutil.copyfile(source, output / "frozen" / name)

    provenance = {
        "assignment_id": "E10",
        "candidate": {
            "candidate_id": "candidate-preservation-envelope",
            "candidate_version": "E05/legendary-e05-result/v1",
            "content_sha256": e05_result["candidate_semantic_sha256"],
            "definition_sha256": digest(EXPERIMENTS / "E05/candidate.json"),
            "runnable_output_sha256": digest(EXPERIMENTS / "E05/outputs/envelopes.jsonl"),
            "source_assignment": "E05",
            "status": "PROVISIONAL_BLOCKED_REWORK",
        },
        "selection_boundary": {
            "fact": "E09 names E05 the strongest non-rejected candidate on its evidence-truth/idempotence axes.",
            "limitation": "E08 rejects E05 on frozen content, hierarchy, accessibility, alias, width, and real-surface evidence; strongest does not mean winner.",
            "winner_selected": False,
        },
        "source_evidence": {
            path: source_ref(path)
            for path in (
                "E03/result.json",
                "E03/candidate-rubric.json",
                "E03/thresholds.json",
                "E05/candidate.json",
                "E05/result.json",
                "E05/outputs/envelopes.jsonl",
                "E07/result.json",
                "E07/rejection-evidence.json",
                "E08/result.json",
                "E08/rejection-evidence.json",
                "E09/result.json",
                "E09/outputs/attack-matrix.json",
                "E09/outputs/rejection-evidence.json",
            )
        },
        "schema_version": "legendary-e10-candidate-provenance/v1",
    }
    write_json(output, "candidate-provenance.json", provenance)

    e08_by_source = {
        item["source_assignment"]: item for item in e08_rejections["rejected_candidates"]
    }
    decisions = {
        "assignment_id": "E10",
        "candidates": {
            candidate: {
                "candidate_id": {
                    "E04": "candidate-canonical-native",
                    "E05": "candidate-preservation-envelope",
                    "E06": "candidate-cohort-rails",
                }[candidate],
                "e08_status": "REJECTED",
                "e08_reasons": e08_by_source[candidate]["reasons"],
                "e09_status": e09_attack["candidate_verdicts"][candidate]["status"],
                "e09_hard_gate_failures": e09_attack["candidate_verdicts"][candidate]["hard_gate_failures"],
                "e10_decision": "BLOCKED_REWORK" if candidate == "E05" else "REJECTED",
            }
            for candidate in ("E04", "E05", "E06")
        },
        "decision_rule": "A candidate must clear every frozen hard threshold. A PASS on one attack axis cannot average away a FAIL or BLOCKED result on another axis.",
        "strongest_candidate": "E05",
        "winner_selected": False,
        "schema_version": "legendary-e10-decision-record/v1",
    }
    write_json(output, "rejected-candidate-decision-record.json", decisions)

    thresholds = load(EXPERIMENTS / "E03/thresholds.json")["thresholds"]
    statuses = {
        "accessibility": "BLOCKED_FAIL_CLOSED",
        "authored_content_preservation": "FAIL_E08_ADV_LONG_CONTENT_7500_TO_7499",
        "build_formula": "BLOCKED_NO_PROVEN_CAPACITY",
        "capacity_rule": "BLOCKED_NO_ACCEPTED_PILOT",
        "idempotence": "PASS_E09_TWO_RUN_STABILITY",
        "pilot_failure_rate": "BLOCKED_NO_ACCEPTED_PILOT",
        "reader_visibility": "BLOCKED_STUDIO_EMAIL_AND_CANDIDATE_SURFACE_CAPTURE",
        "render_test_gate": "FAIL_NOT_ALL_DECLARED_REAL_SURFACE_GATES_PASS",
        "rollback": "PASS_E09_36_OF_36_RESTORED",
        "schema_validity": "PASS_E05_LOCAL_VALIDATION_ONLY",
        "structural_completeness": "FAIL_E08_NESTED_LIST_TABLE_COLLAPSE",
        "surface_exercise": "BLOCKED_AUTHENTICATED_STUDIO_AND_REAL_EMAIL",
        "width_overflow": "BLOCKED_REAL_TUI_EMAIL_AND_ASSISTIVE_TECH_PROOF",
    }
    outcomes = {
        "assignment_id": "E10",
        "frozen_rubric_sha256": digest(EXPERIMENTS / "E03/candidate-rubric.json"),
        "frozen_thresholds_sha256": digest(EXPERIMENTS / "E03/thresholds.json"),
        "hard_gate_policy": "Every threshold must PASS; BLOCKED, FAIL, PARTIAL, or NOT_APPLICABLE cannot select a winner.",
        "outcomes": {
            key: {"requirement": thresholds[key], "status": statuses[key]}
            for key in sorted(thresholds)
        },
        "summary": {
            "blocked_or_failed": sum(not value.startswith("PASS") for value in statuses.values()),
            "passed": sum(value.startswith("PASS") for value in statuses.values()),
            "total": len(statuses),
        },
        "winner_gate": "FAIL",
        "schema_version": "legendary-e10-threshold-outcomes/v1",
    }
    write_json(output, "threshold-outcomes.json", outcomes)

    next_three = {
        "assignment_id": "E10",
        "dispatch_rule": "Dispatch all three assignments as one complete experiment round. Do not start a pilot or builder fan-out unless all three independently PASS every applicable frozen E03 hard threshold.",
        "assignment_count": 3,
        "canonical_id_policy": "The leader allocates authoritative ids; E10 does not invent or publish Task ids.",
        "assignments": [
            {
                "assignment_key": "real-five-surface-proof",
                "objective": "Materialize the unchanged E05 candidate on real representative fixtures and capture authenticated Studio, deterministic TUI, public reader, CLI/API, and real-client email evidence including assistive reading order and narrow-width overflow.",
                "minimum_counts": {"fixtures": 36, "surfaces_per_fixture": 5, "surface_cells": 180},
                "gate": "PASS only with 180/180 real traceable cells, zero critical/high accessibility defects, zero silent blanks, and zero clipping/content loss; proxy or scratch renders are BLOCKED.",
            },
            {
                "assignment_key": "preservation-structure-alias-repair",
                "objective": "Repair E05 without changing source authority so adv-long-content preserves 7500/7500 characters, adv-nested-list-table retains heading/list/table hierarchy, and a newly frozen unsupported-alias adversarial fixture degrades explicitly.",
                "minimum_counts": {"existing_adversarial": 6, "new_unsupported_alias": 1, "two_run_replays": 2},
                "gate": "PASS only with 100% authored preservation, semantic hierarchy preservation, valid schema, explicit alias containment, identical second-run semantic hashes, and residue-free rollback for every fixture.",
            },
            {
                "assignment_key": "sealed-blind-authority-proof",
                "objective": "Seal and independently score paired Task classification/authority records before revealing expected labels, then replay candidate provenance, quarantine, idempotence, and rollback from raw captures.",
                "minimum_counts": {"sealed_paired_records": 20, "candidate_runs": 2, "frozen_fixtures": 36},
                "gate": "PASS only with at least 20 pre-sealed paired records, zero guessed/fabricated authority decisions, complete raw reproduction, identical second-run semantic hashes, and 36/36 pre-image restoration.",
            },
        ],
        "stop_condition": "If any assignment FAILS or is BLOCKED, keep convergence open and schedule another complete three-assignment round; never promote the strongest partial candidate.",
        "schema_version": "legendary-e10-next-complete-three/v1",
    }
    write_json(output, "next-complete-three.json", next_three)

    timings = {
        "assignment_id": "E10",
        "measurement_policy": "Upstream accepted frozen measurements are preserved; ordinary E10 verification reports current elapsed time to stdout and does not rewrite tracked evidence.",
        "upstream": {
            "E07": load(EXPERIMENTS / "E07/timing.json"),
            "E08": load(EXPERIMENTS / "E08/timing.json"),
            "E09": load(EXPERIMENTS / "E09/timing.json"),
        },
        "schema_version": "legendary-e10-timing/v1",
    }
    write_json(output, "timing.json", timings)

    artifact_names = [
        "candidate-provenance.json",
        "frozen/candidate-rubric.json",
        "frozen/thresholds.json",
        "next-complete-three.json",
        "rejected-candidate-decision-record.json",
        "threshold-outcomes.json",
        "timing.json",
    ]
    artifact_hashes = {name: digest(output / name) for name in artifact_names}
    result = {
        "assignment_id": "E10",
        "artifact_hashes": artifact_hashes,
        "builder_gate": {
            "command": "python3 .omx/state/legendary-experiments/E10/scripts/builder_gate.py",
            "expected_exit": 42,
            "expected_output": "E10 BUILDER GATE BLOCKED",
            "status": "BLOCKED",
        },
        "candidate": provenance["candidate"],
        "capability_blocks": sorted(set(e08_result["capability_blocks"] + e09_result["capability_blocks"])),
        "counts": {
            "frozen_fixtures": e03_result["counts"]["total"],
            "papers": e03_result["counts"]["papers"],
            "tasks": e03_result["counts"]["tasks"],
            "adversarial": e03_result["counts"]["adversarial"],
            "candidates_considered": 3,
            "candidates_rejected": 2,
            "candidates_blocked_rework": 1,
            "winners": 0,
            "frozen_thresholds": len(thresholds),
            "thresholds_passed": outcomes["summary"]["passed"],
            "thresholds_blocked_or_failed": outcomes["summary"]["blocked_or_failed"],
            "next_round_assignments": 3,
        },
        "probes": [
            "Reconciled E03 frozen rubric and thresholds by physical SHA-256.",
            "Reconciled E07-E09 candidate decisions and capability blocks.",
            "Pinned E05 semantic, definition, and runnable-output hashes.",
            "Executed deterministic E10 rebuild and fail-closed builder gate in scripts/verify.py.",
        ],
        "schema_version": "legendary-e10-result/v1",
        "stop_condition": "Triggered: every Round-2 candidate failed or remained blocked on at least one frozen hard gate. Start the exact complete-three rework round in next-complete-three.json; do not begin pilot or builder fan-out.",
        "threshold_outcomes_path": "threshold-outcomes.json",
        "timing_path": "timing.json",
        "validation": {
            "command": "python3 .omx/state/legendary-experiments/E10/scripts/verify.py",
            "expected_output": "E10 VERIFY PASS",
            "status": "PASS",
        },
        "verdict": {
            "action": "REWORK",
            "quality": "BLOCKED",
            "winner_selected": False,
            "reason": "E05 is the strongest provisional candidate but does not clear the frozen hard gates; E04 and E06 are rejected.",
        },
    }
    write_json(output, "result.json", result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=E10)
    args = parser.parse_args()
    build(args.output.resolve())
    print("E10 BUILD PASS")


if __name__ == "__main__":
    main()
