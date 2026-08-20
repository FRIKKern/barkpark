#!/usr/bin/env python3
"""Verify E06 frozen inputs, routing, hashes, idempotence, and rollback."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STABLE = ["fixture-manifest.json", "dispatch-manifest.json", "rail-manifest.json", "quarantine-contract.json", "rollback-manifest.json", "outputs/candidates.json", "scorecard.json", "surface-matrix.json"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name: str) -> object:
    return json.loads((ROOT / name).read_text())


def run_dispatch() -> None:
    subprocess.run(["python3", str(ROOT / "scripts/dispatch.py")], check=True, capture_output=True, text=True)


def main() -> None:
    manifest = load("fixture-manifest.json")
    assert manifest["counts"] == {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36}
    for name, key in [("frozen/e03-fixture-manifest.json", "fixture_manifest_sha256"), ("fixtures/selected-source-documents.json", "selected_source_sha256"), ("frozen/thresholds.json", "thresholds_sha256"), ("frozen/failure-taxonomy.json", "failure_taxonomy_sha256"), ("frozen/candidate-rubric.json", "candidate_rubric_sha256")]:
        assert sha(ROOT / name) == manifest["source"][key]
    for row in manifest["adversarial"]:
        assert sha(ROOT / row["path"]) == row["sha256"]
    assert sha(ROOT / manifest["explicit_empty_paper_exclusions"]["path"]) == manifest["explicit_empty_paper_exclusions"]["sha256"]

    first = {name: sha(ROOT / name) for name in STABLE}
    run_dispatch()
    second = {name: sha(ROOT / name) for name in STABLE}
    assert first == second

    dispatch = load("dispatch-manifest.json")
    decisions = dispatch["decisions"]
    assert len(decisions) == 33
    assert len({(row["kind"], row["id"]) for row in decisions}) == 33
    assert all(row["rail"] and row["outcome"] in {"accepted", "quarantined", "excluded"} for row in decisions)
    assert sum(row["outcome"] == "excluded" for row in decisions) == 6
    assert sum(row["rail"] == "task-probe-retirement-review" for row in decisions) == 3
    assert sum(row["rail"] == "paper-empty-probe-evidence-gate" for row in decisions) == 3
    assert all(row["outcome"] == "quarantined" for row in decisions if row["cohort_or_class"] == "unsupported_nested")
    assert all(row["outcome"] != "accepted" for row in decisions if row["kind"] == "task" and ("human review" in row["reason"] or row["cohort_or_class"] == "decision_or_human_gate"))

    rollback = load("rollback-manifest.json")
    assert len(rollback["units"]) == 30
    assert all(row["before_sha256"] == row["restoration_sha256"] for row in rollback["units"])
    outputs = load("outputs/candidates.json")
    assert all(row["semantic_sha256"] == hashlib.sha256(json.dumps(row["document"], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest() for row in outputs["units"])
    rollback_by_id = {row["id"]: row for row in rollback["units"]}
    for row in outputs["units"]:
        if row["rail"] != "paper-markdown-to-portabledoc":
            continue
        source_body = rollback_by_id[row["id"]]["preimage"]["body"]
        markdown = source_body if isinstance(source_body, str) else source_body.get("markdown", "")
        expected = "\n\n".join(part.strip() for part in markdown.replace("\r\n", "\n").split("\n\n") if part.strip())
        actual = "\n\n".join(block["text"] for block in row["document"]["body"]["blocks"])
        assert expected == actual
        assert all(block["type"] == "paragraph" and isinstance(block["text"], str) for block in row["document"]["body"]["blocks"])
    quarantine = load("quarantine-contract.json")
    rejected = {(row["kind"], row["id"]) for row in decisions if row["outcome"] != "accepted"}
    assert {(row["kind"], row["id"]) for row in quarantine["units"]} == rejected
    scorecard = load("scorecard.json")
    assert scorecard["counts"] == {"accepted": 11, "excluded": 6, "quarantined": 16}
    assert all(row["full_gate_declared"] for row in scorecard["rails"])
    frozen_threshold_keys = set(load("frozen/thresholds.json")["thresholds"])
    assert frozen_threshold_keys <= set(scorecard["hard_thresholds"])
    assert all(frozen_threshold_keys <= set(row["threshold_results"]) for row in scorecard["rails"])
    surface_matrix = load("surface-matrix.json")
    assert not any(row["surface"] in {"Studio", "email"} and row["status"] == "PASS" for row in surface_matrix["cells"])
    volatile_timing = load(".replay/timing.json")
    assert volatile_timing["tracked"] is False and volatile_timing["wall_seconds"] > 0
    result = {
        "schema_version": "legendary-e06-result/v1",
        "assignment_id": "E06",
        "round": 2,
        "candidate_id": "candidate-cohort-rails",
        "candidate_ids": ["candidate-cohort-rails"],
        "input_hashes": manifest["source"],
        "fixture_manifest_path": "fixture-manifest.json",
        "fixture_manifest_sha256": sha(ROOT / "fixture-manifest.json"),
        "counts": scorecard["counts"],
        "probes": {"frozen_units": 36, "routed_units": 33, "adversarial_hash_probes": 6, "idempotence_runs": 2, "rollback_checks": 30},
        "commands_or_probes": ["python3 scripts/build_fixtures.py", "python3 scripts/dispatch.py", "python3 scripts/verify.py", "two consecutive dispatcher runs with canonical artifact hash comparison", "30 scratch preimage restoration hash checks"],
        "timing": load("timing.json"),
        "artifact_hashes": {name: sha(ROOT / name) for name in STABLE},
        "hard_thresholds": scorecard["hard_thresholds"],
        "capability_blocks": ["authenticated Studio unavailable", "real-client email unavailable", "no deterministic reader/accessibility/width render harness in isolated scratch candidate"],
        "observed_facts": ["33 units route exactly once with overlap zero: 30 E03 selected units plus three accepted-survey empty Paper exclusions.", "Six retirement/exclusion candidates are explicit: three empty Papers without raw E03 rows and three Task probes with retire signals.", "All 16 ambiguous or unsupported units quarantine rather than guess.", "Two dispatcher runs produced identical canonical hashes for all stable artifacts; 30/30 scratch preimages restore by hash."],
        "inferences": ["Cohort-specific rails are materially distinct from a universal normalization or compatibility envelope.", "Local scratch success does not prove reader, Studio, email, accessibility, or width behavior."],
        "recommendations": ["REWORK by adding deterministic scratch reader, accessibility, and narrow-width harnesses.", "Keep authenticated Studio and real-client email BLOCKED until real evidence exists.", "Do not select a winner from this experimenter artifact."],
        "unresolved_unknowns": ["No raw E03 rows exist for the three empty draft Paper probes.", "Authenticated Studio and real-client email behavior remain unavailable."],
        "surface_matrix": {"path": "surface-matrix.json", "sha256": sha(ROOT / "surface-matrix.json")},
        "threshold_results": scorecard["hard_thresholds"],
        "evidence_paths": STABLE + ["fixtures/empty-paper-exclusions.json", "timing.json"],
        "validation": {"status": "PASS", "command": "bash run.sh", "expected_output": "E06 VERIFY PASS"},
        "risks": ["Blocked hard surfaces prevent a complete PASS.", "Survey-only empty Paper facts cannot receive content repair without inventing evidence."],
        "stop_condition": "Local nondeterminism, overlap, silent exclusion, or a rail missing the frozen threshold set would reject the candidate; none occurred. Frozen surface capability blocks still require REWORK.",
        "hard_gate_outcomes": [{"gate": "deterministic exactly-one routing and overlap zero", "status": "PASS"}, {"gate": "explicit empty/retirement exclusions", "status": "PASS"}, {"gate": "ambiguous and unsupported quarantine", "status": "PASS"}, {"gate": "comparable full threshold set per rail", "status": "PASS"}, {"gate": "authenticated Studio and real-client email", "status": "BLOCKED"}],
        "verdict": {"quality": "PARTIAL", "action": "REWORK"},
        "reason": "Cohort routing, quarantine, exclusions, preservation, rollback, and idempotence pass, but frozen reader, Studio, email, accessibility, and width gates remain blocked. This artifact cannot self-select as winner.",
    }
    (ROOT / "result.json").write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    print("E06 VERIFY PASS")
    print("units=33 accepted=11 quarantined=16 excluded=6 overlap=0 idempotence=PASS rollback=30/30")
    print(f"dispatch_sha256={sha(ROOT / 'dispatch-manifest.json')}")
    print(f"scorecard_sha256={sha(ROOT / 'scorecard.json')}")
    print(f"result_sha256={sha(ROOT / 'result.json')}")
    print(f"volatile_wall_seconds={volatile_timing['wall_seconds']}")


if __name__ == "__main__":
    main()
