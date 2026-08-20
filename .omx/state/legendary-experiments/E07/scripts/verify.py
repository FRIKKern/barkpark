#!/usr/bin/env python3
"""Verify E07 inputs, matrix completeness, truthfulness, and replay stability."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STABLE = ["attack-roster.json", "surface-matrix.json", "candidate-scorecards.json", "threshold-outcomes.json", "rejection-evidence.json", "timing.json"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name: str):
    return json.loads((ROOT / name).read_text())


def run_attack() -> None:
    subprocess.run(["python3", str(ROOT / "scripts/attack.py")], check=True, capture_output=True, text=True)


def result_document() -> dict:
    roster = load("attack-roster.json")
    matrix = load("surface-matrix.json")
    scorecards = load("candidate-scorecards.json")["candidates"]
    thresholds = load("threshold-outcomes.json")["outcomes"]
    rejections = load("rejection-evidence.json")
    assert roster["fixture_count"] == 36 and roster["candidate_count"] == 3 and roster["surface_count"] == 5
    assert roster["expected_cell_count"] == matrix["cell_count"] == 540
    assert matrix["status_counts"] == {"pass": 102, "fail": 6, "blocked": 432}
    assert len({(row["assignment_id"], row["fixture_kind"], row["fixture_id"], row["surface"]) for row in matrix["cells"]}) == 540
    assert not any(row["surface"] in {"authenticated_studio", "public_reader", "tui", "real_client_email"} and row["status"] == "PASS" for row in matrix["cells"])
    assert all(row["candidate_specific_capture"] for row in matrix["cells"] if row["status"] == "PASS")
    assert {row["candidate_id"] for row in scorecards} == set(rejections["rejected_candidates"])
    assert all(row["hard_gate"] == "REJECTED" and row["verdict"] == "BLOCKED_REWORK" for row in scorecards)
    assert next(row for row in scorecards if row["assignment_id"] == "E04")["counts"] == {"pass": 36, "fail": 0, "blocked": 144}
    assert next(row for row in scorecards if row["assignment_id"] == "E05")["counts"] == {"pass": 36, "fail": 0, "blocked": 144}
    assert next(row for row in scorecards if row["assignment_id"] == "E06")["counts"] == {"pass": 30, "fail": 6, "blocked": 144}
    assert thresholds["surface_exercise"].startswith("FAIL_")
    assert thresholds["reader_visibility"].startswith("FAIL_")
    assert thresholds["width_overflow"].startswith("BLOCKED_")
    timing = load("timing.json")
    assert timing["measurement"] == "original_e07_run" and timing["immutable"] is True
    volatile_timing = load(".replay/timing.json")
    assert volatile_timing["tracked"] is False and volatile_timing["wall_seconds"] > 0

    return {
        "schema_version": "legendary-e07-result/v1",
        "assignment_id": "E07",
        "round": 3,
        "candidate_ids": [row["candidate_id"] for row in scorecards],
        "counts": {"candidates": 3, "fixtures": 36, "surfaces": 5, "cells": 540, **matrix["status_counts"]},
        "candidate_counts": {row["candidate_id"]: row["counts"] for row in scorecards},
        "probes": {
            "matrix_uniqueness": "540/540 unique candidate-fixture-surface cells",
            "candidate_specific_local_records": "102/108 CLI/API cells",
            "missing_candidate_records": "6/108 CLI/API cells, all E06 adversarial fixtures",
            "authenticated_studio": "0/108 exercised; BLOCKED",
            "public_reader": "0/108 candidate-specific renders; BLOCKED",
            "tui": "0/108 candidate-specific narrow-width renders; BLOCKED",
            "real_client_email": "0/108 delivered real-client renders; BLOCKED",
            "idempotence": "two E07 attack builds produced identical stable artifact hashes",
        },
        "commands_or_probes": ["bash run.sh", "python3 scripts/attack.py", "python3 scripts/verify.py", "two consecutive stable artifact hash comparisons"],
        "artifact_hashes": {name: sha(ROOT / name) for name in STABLE + ["timing.json"]},
        "input_hashes": roster["frozen_inputs"],
        "threshold_outcomes": thresholds,
        "rejected_candidates": rejections["rejected_candidates"],
        "capability_blocks": rejections["capability_blocks"],
        "proxy_evidence_rejected": rejections["proxy_evidence_rejected"],
        "timing": timing,
        "volatile_timing_path": ".replay/timing.json",
        "validation": {"status": "PASS", "command": "bash run.sh", "expected_output": "E07 VERIFY PASS"},
        "hard_gate_outcome": "REJECTED_ALL_CANDIDATES",
        "verdict": {"quality": "BLOCKED", "action": "REWORK"},
        "reason": "All candidates lack candidate-specific evidence on four required real reader surfaces. E06 additionally lacks output or explicit rejection evidence for six adversarial fixtures. E03 source probes were intentionally not proxy-counted.",
        "stop_condition": "Triggered: authenticated Studio and real-client email capability are unavailable, so E07 returns BLOCKED rather than proxy-PASS.",
    }


def result_bytes() -> bytes:
    return json.dumps(result_document(), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def main() -> None:
    first = {name: sha(ROOT / name) for name in STABLE}
    run_attack()
    second = {name: sha(ROOT / name) for name in STABLE}
    assert first == second

    first_result = result_bytes()
    (ROOT / "result.json").write_bytes(first_result)
    tracked_first = {name: sha(ROOT / name) for name in STABLE + ["result.json"]}

    run_attack()
    second_result = result_bytes()
    (ROOT / "result.json").write_bytes(second_result)
    tracked_second = {name: sha(ROOT / name) for name in STABLE + ["result.json"]}
    assert first_result == second_result
    assert tracked_first == tracked_second

    print("E07 VERIFY PASS")
    print("candidates=3 fixtures=36 surfaces=5 cells=540 pass=102 fail=6 blocked=432")
    print("tracked_replay_bytes=STABLE clean_tree_contract=PASS")
    print("verdict=BLOCKED action=REWORK rejected=3")
    print(f"matrix_sha256={sha(ROOT / 'surface-matrix.json')}")
    print(f"result_sha256={sha(ROOT / 'result.json')}")


if __name__ == "__main__":
    main()
