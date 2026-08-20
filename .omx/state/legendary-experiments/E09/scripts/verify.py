#!/usr/bin/env python3
"""Verify the E09 attack is replayable, complete, and honestly blocked."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path):
    return json.loads(path.read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E09 VERIFY FAIL: {message}")


def main() -> None:
    stable = [ROOT / "outputs/attack-matrix.json", ROOT / "outputs/rejection-evidence.json", ROOT / "timing.json", ROOT / "result.json"]
    first = {str(path.relative_to(ROOT)): sha(path) for path in stable}
    proc = subprocess.run([sys.executable, str(ROOT / "scripts/attack.py")], capture_output=True, text=True)
    require(proc.returncode == 0, "attack replay command")
    second = {str(path.relative_to(ROOT)): sha(path) for path in stable}
    require(first == second, "E09 tracked artifact byte drift")

    matrix = load(ROOT / "outputs/attack-matrix.json")
    result = load(ROOT / "result.json")
    rejection = load(ROOT / "outputs/rejection-evidence.json")
    require(matrix["frozen_e03"]["counts"] == {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36}, "frozen fixture counts")
    require(matrix["blind_gate"]["status"] == "BLOCKED" and matrix["blind_gate"]["sealed_record_count"] == 0, "unsealed blind gate")
    require(set(matrix["candidates"]) == {"E04", "E05", "E06"}, "candidate coverage")
    for candidate, evidence in matrix["candidates"].items():
        require(evidence["runs"] == 2 and evidence["exit_codes"] == [0, 0], f"{candidate} paired replay")
        require(evidence["second_run_semantic_hash_stable"], f"{candidate} idempotence")
        require(evidence["rollback"]["restored"] == evidence["rollback"]["eligible"], f"{candidate} rollback")
        require(evidence["pagination"]["pagination_independent"], f"{candidate} pagination independence")
    require(matrix["candidates"]["E04"]["classification"]["guessed_or_fabricated_decision"], "E04 provenance/classification rejection")
    require(matrix["candidates"]["E05"]["classification"]["authority_gated_task_annotations"] == 18, "E05 authority gating")
    require(matrix["candidates"]["E06"]["raw_reproduction"]["adversarial_fixtures_exercised"] == 0, "E06 adversarial omission detection")
    require(rejection["rejected_candidates"] == ["E04", "E06"], "rejected candidate set")
    require(rejection["blocked_candidates"] == ["E05"], "blocked candidate set")
    require(result["verdict"] == {
        "quality": "PARTIAL",
        "action": "REWORK",
        "winner_selected": False,
        "strongest_non_rejected_candidate": "E05",
        "reason": "E04 and E06 violate hard gates; E05 remains blocked by unsealed blind records and frozen real-surface capability gaps.",
    }, "explicit verdict")
    require(result["stop_condition"]["status"] == "TRIGGERED", "stop condition")
    require(result["artifact_hashes"] == {
        "outputs/attack-matrix.json": sha(ROOT / "outputs/attack-matrix.json"),
        "outputs/rejection-evidence.json": sha(ROOT / "outputs/rejection-evidence.json"),
        "timing.json": sha(ROOT / "timing.json"),
    }, "artifact hash index")
    volatile = load(ROOT / ".replay/timing.json")
    require(volatile["tracked"] is False and volatile["total_wall_seconds"] > 0, "fresh volatile timing")
    print("E09 VERIFY PASS")
    print("candidates=3 runs=6 rejected=2 blocked=1 rollback=102/102 blind_records=0 verdict=PARTIAL/REWORK")
    print(f"attack_matrix_sha256={sha(ROOT / 'outputs/attack-matrix.json')}")
    print(f"result_sha256={sha(ROOT / 'result.json')}")


if __name__ == "__main__":
    main()
