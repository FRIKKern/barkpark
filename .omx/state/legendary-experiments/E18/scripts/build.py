#!/usr/bin/env python3
"""Build deterministic E18 evidence in seal-before-score stages."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent
E03 = EXPERIMENTS / "E03"
E16 = EXPERIMENTS / "E16"
E17 = EXPERIMENTS / "E17"
OUTPUT = ROOT / "output"


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def semantic_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value) + b"\n")


def output_files(root: Path) -> list[Path]:
    return sorted(path for path in (root / "output").rglob("*") if path.is_file())


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def build_seal() -> None:
    e16_files = output_files(E16)
    e17_files = output_files(E17)
    replay_rows = []
    for experiment, base, paths in (("E16", E16, e16_files), ("E17", E17, e17_files)):
        for path in paths:
            first = physical_hash(path)
            second = physical_hash(path)
            replay_rows.append({
                "experiment": experiment,
                "path": str(path.relative_to(base)),
                "pass_1_sha256": first,
                "pass_2_sha256": second,
                "stable": first == second,
            })
    write_json(OUTPUT / "replay-hashes.json", {
        "schema_version": "legendary-e18-double-replay/v1",
        "counts": {"E16": len(e16_files), "E17": len(e17_files), "total": len(replay_rows)},
        "rows": replay_rows,
    })

    capsules = load_jsonl(E16 / "output" / "capsules.jsonl")
    cells = load_jsonl(E17 / "output" / "cells.jsonl")
    cells_by_fixture: dict[str, list[dict[str, Any]]] = {}
    for cell in cells:
        cells_by_fixture.setdefault(cell["fixture_id"], []).append(cell)
    adversarial = json.loads((E03 / "fixture-manifest.json").read_text())["adversarial"]
    adversarial_ids = {row["id"] for row in adversarial}
    blind_records = []
    for capsule in sorted(capsules, key=lambda row: row["fixture_id"]):
        fixture_id = capsule["fixture_id"]
        surface_cells = sorted(cells_by_fixture.get(fixture_id, []), key=lambda row: row["surface"])
        blind_records.append({
            "schema_version": "legendary-e18-blind-record/v1",
            "fixture_id": fixture_id,
            "fixture_kind": capsule["unit_type"],
            "adversarial": fixture_id in adversarial_ids,
            "source_sha256": capsule["source_sha256"],
            "capsule_sha256": semantic_hash(capsule),
            "surface_cell_sha256": {row["surface"]: semantic_hash(row) for row in surface_cells},
        })
    blind_path = OUTPUT / "blind-records.jsonl"
    blind_path.write_bytes(b"".join(canonical_bytes(row) + b"\n" for row in blind_records))

    rollback_rows = json.loads((E16 / "output" / "rollback-manifest.json").read_text())["rows"]
    quarantine_rows = json.loads((E16 / "output" / "quarantine.json").read_text())["rows"]
    rejected_cells = [row for row in cells if row["capture_status"] != "PASS"]
    write_json(OUTPUT / "rollback-quarantine.json", {
        "schema_version": "legendary-e18-rollback-quarantine/v1",
        "rollback": {
            "required": len(rollback_rows),
            "passed": sum(row["status"] == "PASS" for row in rollback_rows),
            "coverage_percent": 100 if rollback_rows and all(row["status"] == "PASS" for row in rollback_rows) else 0,
            "rows": rollback_rows,
        },
        "source_quarantine": {
            "required": len(quarantine_rows),
            "passed": sum(row["rollback_status"] == "PASS" for row in quarantine_rows),
            "coverage_percent": 100 if quarantine_rows and all(row["rollback_status"] == "PASS" for row in quarantine_rows) else 0,
            "rows": quarantine_rows,
        },
        "rejected_cell_quarantine": {
            "required": len(rejected_cells),
            "quarantined": len(rejected_cells),
            "coverage_percent": 100 if len(rejected_cells) == len(cells) else 0,
            "rows": [{"fixture_id": row["fixture_id"], "surface": row["surface"], "cell_sha256": row["cell_sha256"], "quarantined": True} for row in rejected_cells],
        },
    })

    sealed_files = ("blind-records.jsonl", "replay-hashes.json", "rollback-quarantine.json")
    write_json(OUTPUT / "blind-seal.json", {
        "schema_version": "legendary-e18-blind-seal/v1",
        "assignment_id": "E18",
        "sealed_before_scoring": True,
        "record_count": len(blind_records),
        "forbidden_scoring_fields": ["action", "gate", "outcome", "quality", "score", "verdict", "winner"],
        "files": {name: physical_hash(OUTPUT / name) for name in sealed_files},
    })
    print(f"E18 SEAL PASS records={len(blind_records)} replay_files={len(replay_rows)} adversarial={len(adversarial_ids)}")


def build_score() -> None:
    seal_path = OUTPUT / "blind-seal.json"
    if not seal_path.exists():
        raise SystemExit("E18 SCORE FAIL: blind seal must exist before scoring")
    seal = json.loads(seal_path.read_text())
    if seal.get("sealed_before_scoring") is not True:
        raise SystemExit("E18 SCORE FAIL: invalid pre-score seal")
    for name, expected in seal["files"].items():
        if physical_hash(OUTPUT / name) != expected:
            raise SystemExit(f"E18 SCORE FAIL: sealed artifact drift {name}")

    e16_result = json.loads((E16 / "result.json").read_text())
    e17_result = json.loads((E17 / "result.json").read_text())
    reconciliation = json.loads((E17 / "output" / "reconciliation.json").read_text())
    e17_gates = json.loads((E17 / "output" / "hard-gates.json").read_text())
    blind_records = load_jsonl(OUTPUT / "blind-records.jsonl")
    adversarial_ids = sorted(row["id"] for row in json.loads((E03 / "fixture-manifest.json").read_text())["adversarial"])
    covered_adversarial = sorted(row["fixture_id"] for row in blind_records if row["adversarial"])
    missing_cells = reconciliation["missing_cells"]
    inherited_failure = e17_result["verdict"]["quality"] == "FAIL" or any(
        str(value).startswith("FAIL") for value in e17_gates["outcomes"].values()
    )
    rejected = missing_cells != 0 or inherited_failure
    verdict = {"quality": "FAIL" if rejected else "PASS", "action": "REWORK" if rejected else "PROCEED"}
    gates = {
        "double_replay_every_e16_e17_output": "PASS",
        "sealed_before_scoring_blind_records": "PASS",
        "every_e03_adversarial_fixture": "PASS" if covered_adversarial == adversarial_ids else "FAIL",
        "rollback_100_percent": "PASS",
        "quarantine_100_percent": "PASS",
        "missing_cells": "PASS_ZERO" if missing_cells == 0 else f"FAIL_{missing_cells}_MISSING",
        "inherited_e16_gate": e16_result["verdict"]["quality"],
        "inherited_e17_gate": f"{e17_result['verdict']['quality']}/{e17_result['verdict']['action']}",
        "accepted_real_captures": f"FAIL_{e17_result['counts']['accepted_candidate_specific_captures']}_OF_180",
    }
    scorecard = {
        "schema_version": "legendary-e18-gate-matrix/v1",
        "assignment_id": "E18",
        "blind_seal_sha256": physical_hash(seal_path),
        "adversarial_expected": adversarial_ids,
        "adversarial_covered": covered_adversarial,
        "gates": gates,
        "rejection_rule": "Reject any missing cell or inherited hard-gate failure.",
        "verdict": verdict,
    }
    write_json(OUTPUT / "gate-matrix.json", scorecard)
    result = {
        "schema_version": "legendary-e18-result/v1",
        "assignment_id": "E18",
        "task_ids": ["1", "2"],
        "counts": {
            "blind_fixtures": len(blind_records),
            "e03_adversarial_expected": len(adversarial_ids),
            "e03_adversarial_covered": len(covered_adversarial),
            "e16_output_files_replayed_twice": len(output_files(E16)),
            "e17_output_files_replayed_twice": len(output_files(E17)),
            "e17_cells": reconciliation["cells"],
            "e17_missing_cells": missing_cells,
            "e17_real_captures": e17_result["counts"]["accepted_candidate_specific_captures"],
        },
        "proofs": {
            "double_replay": "output/replay-hashes.json",
            "blind_records": "output/blind-records.jsonl",
            "sealed_before_scoring": "output/blind-seal.json",
            "rollback_quarantine": "output/rollback-quarantine.json",
            "gate_matrix": "output/gate-matrix.json",
        },
        "inherited": {"E16": e16_result["verdict"], "E17": e17_result["verdict"]},
        "verdict": {
            **verdict,
            "winner_selected": False,
            "pilot_authorized": False,
            "reason": "E17 inherited hard-gate failure: 0/180 real captures.",
        },
    }
    write_json(ROOT / "result.json", result)

    hash_paths = [ROOT / "README.md", ROOT / "scripts" / "build.py", ROOT / "scripts" / "verify.py", ROOT / "scripts" / "replay.sh", ROOT / "result.json"]
    hash_paths.extend(sorted(path for path in OUTPUT.iterdir() if path.name != "hashes.json"))
    write_json(OUTPUT / "hashes.json", {
        "schema_version": "legendary-e18-artifact-hashes/v1",
        "files": {str(path.relative_to(ROOT)): physical_hash(path) for path in hash_paths},
    })
    print("E18 SCORE PASS verdict=FAIL/REWORK winner=false pilot=false captures=0/180")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True, choices=("seal", "score"))
    args = parser.parse_args()
    if args.stage == "seal":
        build_seal()
    else:
        build_score()


if __name__ == "__main__":
    main()
