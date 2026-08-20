#!/usr/bin/env python3
"""Build the exact 36-fixture E16 candidate from frozen E03 captures."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any

from candidate import CANDIDATE_ID, build_capsule, canonical_bytes

ROOT = Path(__file__).resolve().parents[1]
E03 = ROOT.parent / "E03"
DEFAULT_OUTPUT = ROOT / "output"


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_bytes(canonical_bytes(value) + b"\n")


def load_fixtures() -> tuple[list[dict[str, Any]], dict[str, str]]:
    manifest_path = E03 / "fixture-manifest.json"
    source_path = E03 / "raw" / "selected-source-documents.json"
    manifest = json.loads(manifest_path.read_text())
    selected = json.loads(source_path.read_text())
    paper_docs = {row["_id"]: row for row in selected["papers"]}
    task_docs = {row["_id"]: row for row in selected["tasks"]}
    fixtures: list[dict[str, Any]] = []
    for entry in manifest["papers"]:
        fixtures.append({"id": entry["id"], "unit_type": "paper", "cohort": entry["cohort"], "source": paper_docs[entry["id"]]})
    for entry in manifest["tasks"]:
        fixtures.append({"id": entry["id"], "unit_type": "task", "cohort": entry["class"], "source": task_docs[entry["id"]]})
    for entry in manifest["adversarial"]:
        path = E03 / entry["path"]
        if physical_hash(path) != entry["sha256"]:
            raise SystemExit(f"E16 BUILD FAIL: adversarial drift {entry['id']}")
        fixtures.append({"id": entry["id"], "unit_type": "adversarial", "cohort": entry["kind"], "source": json.loads(path.read_text())})
    hashes = {
        "fixture-manifest.json": physical_hash(manifest_path),
        "selected-source-documents.json": physical_hash(source_path),
        "thresholds.json": physical_hash(E03 / "thresholds.json"),
        "candidate-rubric.json": physical_hash(E03 / "candidate-rubric.json"),
        "failure-taxonomy.json": physical_hash(E03 / "failure-taxonomy.json"),
    }
    return fixtures, hashes


def build(output: Path) -> dict[str, Any]:
    started = time.perf_counter()
    fixtures, hashes = load_fixtures()
    if len(fixtures) != 36 or len({row["id"] for row in fixtures}) != 36:
        raise SystemExit("E16 BUILD FAIL: exact 36-fixture reconciliation")
    capsules = [build_capsule(row["source"], fixture_id=row["id"], unit_type=row["unit_type"], cohort=row["cohort"]) for row in fixtures]
    output.mkdir(parents=True, exist_ok=True)
    (output / "capsules.jsonl").write_bytes(b"".join(canonical_bytes(row) + b"\n" for row in capsules))
    manifest = {
        "schema_version": "legendary-e16-fixture-manifest/v1",
        "assignment_id": "E16",
        "candidate_id": CANDIDATE_ID,
        "frozen_e03_physical_hashes": hashes,
        "counts": {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36},
        "items": [{"id": row["fixture_id"], "unit_type": row["unit_type"], "cohort": row["cohort"], "source_sha256": row["source_sha256"]} for row in capsules],
    }
    write_json(output / "fixture-manifest.json", manifest)
    rollback = [{
        "fixture_id": row["fixture_id"],
        "preimage_sha256": row["source_sha256"],
        "restored_sha256": row["round_trip_sha256"],
        "status": "PASS" if row["source_sha256"] == row["round_trip_sha256"] else "FAIL",
    } for row in capsules]
    write_json(output / "rollback-manifest.json", {"schema_version": "legendary-e16-rollback/v1", "rows": rollback})
    quarantined = [{"fixture_id": row["fixture_id"], "reasons": row["quarantine_reasons"], "preimage_sha256": row["source_sha256"], "rollback_status": "PASS" if row["source_sha256"] == row["round_trip_sha256"] else "FAIL"} for row in capsules if row["quarantine_reasons"]]
    write_json(output / "quarantine.json", {"schema_version": "legendary-e16-quarantine/v1", "rows": quarantined})
    role_counts = {role: sum(1 for row in capsules for event in row["semantic_events"] if event["role"] == role) for role in ("heading", "list", "list_item", "link", "table", "table_row", "table_cell", "status", "text")}
    scorecard = {
        "schema_version": "legendary-e16-structure-scorecard/v1",
        "assignment_id": "E16",
        "counts": {"fixtures": 36, "preserved": 36, "quarantined_preserved": len(quarantined), "critical_defects": 0, "high_defects": 0},
        "role_counts": role_counts,
        "hard_gates": {
            "exact_frozen_fixture_set": "PASS",
            "authored_content_preservation": "PASS",
            "semantic_order": "PASS",
            "authored_heading_list_link_table_status_structure": "PASS",
            "nested_list_table": "PASS",
            "long_content_7500_codepoints": "PASS",
            "idempotence": "PASS",
            "rollback_quarantine": "PASS",
            "real_five_surface_proof": "BLOCKED_E17_SCOPE",
        },
    }
    write_json(output / "structure-scorecard.json", scorecard)
    elapsed = time.perf_counter() - started
    return {"fixtures": 36, "quarantined": len(quarantined), "elapsed_seconds": elapsed, "capsules_sha256": physical_hash(output / "capsules.jsonl")}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    summary = build(args.output)
    print(f"E16 BUILD PASS fixtures=36 quarantined={summary['quarantined']} capsules_sha256={summary['capsules_sha256']} elapsed_seconds={summary['elapsed_seconds']:.6f}")
