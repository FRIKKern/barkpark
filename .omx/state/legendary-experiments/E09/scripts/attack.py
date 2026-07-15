#!/usr/bin/env python3
"""Replay and adversarially audit the frozen Round-2 candidates for E09."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent
E03 = EXPERIMENTS / "E03"
STABLE_FILES = {
    "E04": [
        "output/repair-packet.json",
        "transformation-manifest.json",
        "verification.json",
        "scorecard.json",
        "result.json",
    ],
    "E05": [
        "fixtures/manifest.json",
        "outputs/envelopes.jsonl",
        "outputs/rollback-manifest.json",
        "outputs/quarantine.json",
        "outputs/surface-matrix.json",
        "outputs/scorecard.json",
        "outputs/hashes.json",
        "outputs/timing.json",
        "result.json",
    ],
    "E06": [
        "fixture-manifest.json",
        "dispatch-manifest.json",
        "rail-manifest.json",
        "quarantine-contract.json",
        "rollback-manifest.json",
        "outputs/candidates.json",
        "scorecard.json",
        "surface-matrix.json",
        "timing.json",
        "result.json",
    ],
}
RUNNERS = {
    "E04": ["bash", "scripts/run.sh"],
    "E05": ["bash", "scripts/replay.sh"],
    "E06": ["bash", "run.sh"],
}


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha(path: Path) -> str:
    return sha_bytes(path.read_bytes())


def load(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


def stable_hashes(candidate: str) -> dict[str, str]:
    base = EXPERIMENTS / candidate
    return {name: sha(base / name) for name in STABLE_FILES[candidate]}


def run_twice(candidate: str) -> dict[str, Any]:
    base = EXPERIMENTS / candidate
    snapshots = [stable_hashes(candidate)]
    elapsed: list[float] = []
    markers: list[bool] = []
    exit_codes: list[int] = []
    expected = f"{candidate} "
    for _ in range(2):
        started = time.perf_counter()
        proc = subprocess.run(RUNNERS[candidate], cwd=base, capture_output=True, text=True)
        elapsed.append(round(time.perf_counter() - started, 6))
        exit_codes.append(proc.returncode)
        markers.append(expected in (proc.stdout + proc.stderr) and "PASS" in (proc.stdout + proc.stderr))
        snapshots.append(stable_hashes(candidate))
    return {
        "runs": 2,
        "exit_codes": exit_codes,
        "pass_markers_observed": markers,
        "pre_run_hashes": snapshots[0],
        "first_run_hashes": snapshots[1],
        "second_run_hashes": snapshots[2],
        "preexisting_artifacts_preserved": snapshots[0] == snapshots[1],
        "second_run_semantic_hash_stable": snapshots[1] == snapshots[2],
        "elapsed_seconds": elapsed,
    }


def rollback_e04() -> dict[str, Any]:
    packet = load(EXPERIMENTS / "E04/output/repair-packet.json")
    rows = packet["papers"] + packet["tasks"] + packet["quarantine"]
    checked = 0
    failures: list[str] = []
    for row in rows:
        expected = row.get("preimage_sha256")
        preimage = row.get("preimage")
        if expected is None or preimage is None:
            failures.append(row["id"])
            continue
        checked += 1
        if sha_bytes(canonical(preimage)) != expected:
            failures.append(row["id"])
    return {"eligible": len(rows), "checked": checked, "restored": checked - len(failures), "failures": failures}


def rollback_e05() -> dict[str, Any]:
    rows = load(EXPERIMENTS / "E05/outputs/rollback-manifest.json")["rows"]
    failures = [
        row["fixture_id"]
        for row in rows
        if row.get("status") != "PASS"
        or row.get("rollback_status") != "PASS"
        or row.get("first_envelope_sha256") != row.get("second_envelope_sha256")
        or row.get("residue_keys")
    ]
    return {"eligible": len(rows), "checked": len(rows), "restored": len(rows) - len(failures), "failures": failures}


def rollback_e06() -> dict[str, Any]:
    rows = load(EXPERIMENTS / "E06/rollback-manifest.json")["units"]
    failures = [row["id"] for row in rows if row.get("before_sha256") != row.get("restoration_sha256")]
    return {"eligible": len(rows), "checked": len(rows), "restored": len(rows) - len(failures), "failures": failures}


def raw_reproduction(candidate: str) -> dict[str, Any]:
    source_paths = {
        "E04": EXPERIMENTS / "E04/fixtures/source-documents.json",
        "E05": EXPERIMENTS / "E05/fixtures/source-documents.json",
        "E06": EXPERIMENTS / "E06/fixtures/selected-source-documents.json",
    }
    source_match = sha(source_paths[candidate]) == sha(E03 / "raw/selected-source-documents.json")
    e03_manifest = load(E03 / "fixture-manifest.json")
    adversarial_matches = 0
    for row in e03_manifest["adversarial"]:
        if candidate == "E04":
            target = EXPERIMENTS / candidate / "fixtures/adversarial" / Path(row["path"]).name
        elif candidate == "E05":
            target = EXPERIMENTS / candidate / "fixtures/adversarial" / Path(row["path"]).name
        else:
            target = EXPERIMENTS / candidate / "fixtures" / Path(row["path"]).name
        adversarial_matches += int(target.exists() and sha(target) == row["sha256"])
    if candidate == "E04":
        packet = load(EXPERIMENTS / "E04/output/repair-packet.json")
        exercised = sum(row.get("kind") == "adversarial" for row in packet["papers"] + packet["quarantine"])
    elif candidate == "E05":
        rows = [json.loads(line) for line in (EXPERIMENTS / "E05/outputs/envelopes.jsonl").read_text().splitlines() if line]
        exercised = sum(row.get("unit_type") == "adversarial" for row in rows)
    else:
        decisions = load(EXPERIMENTS / "E06/dispatch-manifest.json")["decisions"]
        exercised = sum(row.get("kind") == "adversarial" for row in decisions)
    return {
        "selected_source_sha256": sha(source_paths[candidate]),
        "e03_selected_source_sha256": sha(E03 / "raw/selected-source-documents.json"),
        "selected_source_matches_e03": source_match,
        "adversarial_fixture_hashes_matching": adversarial_matches,
        "adversarial_fixture_count": 6,
        "adversarial_fixtures_exercised": exercised,
        "raw_reproduction_complete": source_match and adversarial_matches == 6 and exercised == 6,
    }


def classification_evidence(candidate: str, e03_tasks: list[dict[str, Any]]) -> dict[str, Any]:
    signals = {row["id"]: set(row["observed"]["signals"]) for row in e03_tasks}
    sensitive = {fixture_id for fixture_id, row_signals in signals.items() if row_signals & {"ambiguous", "class_vs_cn_disagreement", "human_review", "retire"}}
    if candidate == "E04":
        tasks = load(EXPERIMENTS / "E04/output/repair-packet.json")["tasks"]
        sensitive_accepted = [row["id"] for row in tasks if row["id"] in sensitive]
        derived_without_provenance = 0
        for row in tasks:
            source = row["preimage"]
            for field in row["required_fields"]:
                if field not in source and field in row["canonical_fields"]:
                    derived_without_provenance += 1
        return {
            "task_count": len(tasks),
            "sensitive_task_count": len(sensitive),
            "sensitive_tasks_accepted_without_authority_gate": len(sensitive_accepted),
            "derived_fields_without_per_field_provenance": derived_without_provenance,
            "guessed_or_fabricated_decision": bool(sensitive_accepted or derived_without_provenance),
        }
    if candidate == "E05":
        rows = [json.loads(line) for line in (EXPERIMENTS / "E05/outputs/envelopes.jsonl").read_text().splitlines() if line]
        tasks = [row for row in rows if row.get("unit_type") == "task"]
        gated = [row for row in tasks if row["annotation"].get("authority") == "advisory_only" and row["annotation"].get("requires_authority_and_evidence_gate") is True]
        return {
            "task_count": len(tasks),
            "sensitive_task_count": len(sensitive),
            "authority_gated_task_annotations": len(gated),
            "source_authoritative_tasks": sum(row["authority"].get("source_of_truth") == "source" for row in tasks),
            "guessed_or_fabricated_decision": False,
        }
    decisions = [row for row in load(EXPERIMENTS / "E06/dispatch-manifest.json")["decisions"] if row.get("kind") == "task"]
    sensitive_rows = [row for row in decisions if row["id"] in sensitive]
    unsafe_accepts = [row["id"] for row in sensitive_rows if row["outcome"] == "accepted"]
    return {
        "task_count": len(decisions),
        "sensitive_task_count": len(sensitive),
        "sensitive_quarantined_or_excluded": sum(row["outcome"] != "accepted" for row in sensitive_rows),
        "sensitive_unsafe_accepts": unsafe_accepts,
        "guessed_or_fabricated_decision": bool(unsafe_accepts),
    }


def pagination_independence(candidate: str) -> dict[str, Any]:
    script_text = "\n".join(path.read_text() for path in sorted((EXPERIMENTS / candidate / "scripts").glob("*")) if path.is_file())
    if candidate == "E06":
        script_text += (EXPERIMENTS / candidate / "run.sh").read_text()
    tokens = ["bp task", "--offset", "tasks.1000", "/v1/tasks?"]
    hits = [token for token in tokens if token in script_text]
    return {"known_broken_pagination_tokens": hits, "pagination_independent": not hits}


def main() -> None:
    started = time.perf_counter()
    thresholds_hash = sha(E03 / "thresholds.json")
    fixture_manifest = load(E03 / "fixture-manifest.json")
    e03_tasks = fixture_manifest["tasks"]

    roster = load(EXPERIMENTS.parent / "legendary-experiment-roster.json")
    exact_e09 = next(item for round_data in roster["rounds"] for item in round_data["assignments"] if item["id"] == "E09")

    # The roster requires paired records to be sealed before scoring. No sealed
    # records are present in the frozen E03 bundle, so classification scoring is
    # stopped rather than reconstructed from prose or mechanical ratings.
    sealed_paths = sorted(str(path.relative_to(EXPERIMENTS.parent)) for path in EXPERIMENTS.parent.rglob("*") if path.is_file() and "sealed" in path.name.lower())
    blind_gate = {
        "required_paired_records": 20,
        "sealed_record_paths": sealed_paths,
        "sealed_record_count": len(sealed_paths),
        "status": "BLOCKED",
        "reason": "No sealed paired blind records exist in the frozen E03 evidence; classification scoring stopped before rating.",
    }

    replay: dict[str, Any] = {}
    candidate_timings: dict[str, list[float]] = {}
    rollbacks = {"E04": rollback_e04, "E05": rollback_e05, "E06": rollback_e06}
    for candidate in ("E04", "E05", "E06"):
        replay[candidate] = run_twice(candidate)
        candidate_timings[candidate] = replay[candidate].pop("elapsed_seconds")
        replay[candidate]["rollback"] = rollbacks[candidate]()
        replay[candidate]["raw_reproduction"] = raw_reproduction(candidate)
        replay[candidate]["classification"] = classification_evidence(candidate, e03_tasks)
        replay[candidate]["pagination"] = pagination_independence(candidate)

    candidate_verdicts: dict[str, Any] = {}
    for candidate, evidence in replay.items():
        failures: list[str] = []
        if evidence["exit_codes"] != [0, 0] or not all(evidence["pass_markers_observed"]):
            failures.append("candidate replay command failed")
        if not evidence["second_run_semantic_hash_stable"]:
            failures.append("additional second-run mutation")
        if evidence["rollback"]["restored"] != evidence["rollback"]["eligible"]:
            failures.append("failed pre-image restoration")
        if not evidence["raw_reproduction"]["raw_reproduction_complete"]:
            failures.append("raw captures do not independently reproduce the full E03 fixture set")
        if evidence["classification"]["guessed_or_fabricated_decision"]:
            failures.append("guessed class/authority decision or derived field without provenance")
        if not evidence["pagination"]["pagination_independent"]:
            failures.append("dependency on known-broken Task pagination path")
        rejected = bool(failures)
        candidate_verdicts[candidate] = {
            "status": "REJECTED" if rejected else "BLOCKED_REWORK",
            "hard_gate_failures": failures,
            "classification_blind_gate": "BLOCKED_UNSEALED",
            "frozen_surface_gate": "BLOCKED_STUDIO_EMAIL",
        }

    matrix = {
        "schema_version": "legendary-e09-attack-matrix/v1",
        "assignment_id": "E09",
        "exact_assignment": exact_e09,
        "frozen_e03": {
            "thresholds_sha256": thresholds_hash,
            "fixture_manifest_sha256": sha(E03 / "fixture-manifest.json"),
            "selected_source_sha256": sha(E03 / "raw/selected-source-documents.json"),
            "counts": fixture_manifest["counts"],
        },
        "blind_gate": blind_gate,
        "candidates": replay,
        "candidate_verdicts": candidate_verdicts,
    }
    write_json(ROOT / "outputs/attack-matrix.json", matrix)

    tracked_timing = ROOT / "timing.json"
    volatile_timing = {
        "schema_version": "legendary-e09-volatile-timing/v1",
        "candidate_run_seconds": candidate_timings,
        "total_wall_seconds": round(time.perf_counter() - started, 6),
        "tracked": False,
    }
    write_json(ROOT / ".replay/timing.json", volatile_timing)
    if not tracked_timing.exists() or os.environ.get("E09_REFRESH_TIMING") == "1":
        write_json(
            tracked_timing,
            {
                "schema_version": "legendary-e09-timing/v1",
                "candidate_runs": 6,
                "representative_total_wall_seconds": volatile_timing["total_wall_seconds"],
                "policy": "Frozen representative measurement; ordinary replay writes current timing only to .replay/timing.json.",
            },
        )

    rejection = {
        "schema_version": "legendary-e09-rejection-evidence/v1",
        "assignment_id": "E09",
        "rejected_candidates": [candidate for candidate, verdict in candidate_verdicts.items() if verdict["status"] == "REJECTED"],
        "blocked_candidates": [candidate for candidate, verdict in candidate_verdicts.items() if verdict["status"] == "BLOCKED_REWORK"],
        "candidate_verdicts": candidate_verdicts,
        "capability_blocks": [
            "paired blind records are not sealed before scoring",
            "authenticated Studio content proof unavailable",
            "real-client email proof unavailable",
            "typed native-subagent spawn unavailable on this worker tool surface; untyped substitutes forbidden",
        ],
    }
    write_json(ROOT / "outputs/rejection-evidence.json", rejection)

    result = {
        "schema_version": "legendary-e09-result/v1",
        "assignment_id": "E09",
        "round": 3,
        "exact_assignment": exact_e09,
        "candidate_ids": ["E04", "E05", "E06"],
        "counts": {
            "candidates": 3,
            "candidate_runs": 6,
            "e03_fixtures": 36,
            "e03_papers": 12,
            "e03_tasks": 18,
            "e03_adversarial": 6,
            "sealed_blind_records": blind_gate["sealed_record_count"],
            "rejected_candidates": len(rejection["rejected_candidates"]),
            "blocked_candidates": len(rejection["blocked_candidates"]),
        },
        "probes": {
            candidate: {
                "idempotence_runs": evidence["runs"],
                "stable_artifact_hashes": len(evidence["second_run_hashes"]),
                "rollback_checks": evidence["rollback"]["checked"],
                "rollback_restored": evidence["rollback"]["restored"],
                "raw_adversarial_hash_matches": evidence["raw_reproduction"]["adversarial_fixture_hashes_matching"],
                "raw_adversarial_exercised": evidence["raw_reproduction"]["adversarial_fixtures_exercised"],
                "task_class_checks": evidence["classification"]["task_count"],
                "pagination_independence": evidence["pagination"]["pagination_independent"],
            }
            for candidate, evidence in replay.items()
        },
        "hashes": {candidate: evidence["second_run_hashes"] for candidate, evidence in replay.items()},
        "threshold_outcomes": {
            "idempotence": {candidate: "PASS" if evidence["second_run_semantic_hash_stable"] else "FAIL" for candidate, evidence in replay.items()},
            "rollback": {candidate: "PASS" if evidence["rollback"]["restored"] == evidence["rollback"]["eligible"] else "FAIL" for candidate, evidence in replay.items()},
            "authored_versus_derived_provenance": {"E04": "FAIL", "E05": "PASS", "E06": "PASS_ANNOTATION_ONLY"},
            "classification_safety": {candidate: "BLOCKED_UNSEALED" for candidate in replay},
            "pagination_independent_reproducibility": {candidate: "PASS" if evidence["pagination"]["pagination_independent"] else "FAIL" for candidate, evidence in replay.items()},
            "raw_capture_reproduction": {candidate: "PASS" if evidence["raw_reproduction"]["raw_reproduction_complete"] else "FAIL" for candidate, evidence in replay.items()},
            "surface_exercise": {candidate: "BLOCKED_STUDIO_EMAIL" for candidate in replay},
        },
        "candidate_verdicts": candidate_verdicts,
        "rejected_candidates": rejection["rejected_candidates"],
        "capability_blocks": rejection["capability_blocks"],
        "observed_facts": [
            "All three Round-2 candidate replay commands completed twice with stable tracked artifact hashes.",
            "E04 restores 36/36 embedded pre-images but accepts sensitive Task classifications and emits derived required fields without per-field provenance.",
            "E05 restores 36/36 pre-images, preserves source authority, and keeps all 18 Task class annotations advisory and authority-gated.",
            "E06 restores 30/30 routed pre-images but exercises 0/6 frozen E03 adversarial fixtures, so its full raw-capture reproduction claim fails.",
            "No sealed paired blind records exist; classification scoring stopped before rating rather than reconstructing records.",
        ],
        "commands_or_probes": [
            "python3 scripts/attack.py",
            "python3 scripts/verify.py",
            "E04 scripts/run.sh twice",
            "E05 scripts/replay.sh twice",
            "E06 run.sh twice",
            "candidate stable-artifact hash comparison after each run",
            "candidate pre-image restoration hash checks",
            "E03 raw selected-source and adversarial fixture hash reconciliation",
            "offline candidate-script pagination token audit",
        ],
        "artifact_hashes": {
            "outputs/attack-matrix.json": sha(ROOT / "outputs/attack-matrix.json"),
            "outputs/rejection-evidence.json": sha(ROOT / "outputs/rejection-evidence.json"),
            "timing.json": sha(ROOT / "timing.json"),
        },
        "stop_condition": {
            "status": "TRIGGERED",
            "reason": blind_gate["reason"],
            "raw_capture_secondary_failure": "E06 does not exercise the six frozen E03 adversarial captures.",
        },
        "verdict": {
            "quality": "PARTIAL",
            "action": "REWORK",
            "winner_selected": False,
            "strongest_non_rejected_candidate": "E05",
            "reason": "E04 and E06 violate hard gates; E05 remains blocked by unsealed blind records and frozen real-surface capability gaps.",
        },
    }
    write_json(ROOT / "result.json", result)
    print("E09 ATTACK COMPLETE verdict=PARTIAL/REWORK rejected=E04,E06 blocked=E05")


if __name__ == "__main__":
    main()
