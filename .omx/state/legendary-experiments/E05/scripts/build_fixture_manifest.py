#!/usr/bin/env python3
"""Build E05's self-contained manifest from exact frozen E03 bytes."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from adapter import semantic_hash


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
EXPECTED_HASHES = {
    "e03-fixture-manifest.json": "0ab24d0a38f9d8db97073accaea37f02786d9c47f7dac3471e858907d5c308df",
    "e03-thresholds.json": "4117e563cb8d261b3256823fc90f16fb0e3d57a51fa84ab8b0a609d3684ecd6b",
    "e03-candidate-rubric.json": "3805ed5afb1ed76c22ba2144aefaf2d5c5e73508fb8f4170d9441e3400d952d4",
    "e03-failure-taxonomy.json": "29fbb60a099ff6607efd87716887f592e2443498c5b65f2b87317ba3e1807ce9",
    "source-documents.json": "803ea48c241c50e9018470837a02071980298b102d7d035182cc99c9e7338cbf",
}


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> None:
    observed = {name: physical_hash(FIXTURES / name) for name in EXPECTED_HASHES}
    if observed != EXPECTED_HASHES:
        raise SystemExit(f"frozen E03 input drift: {observed}")

    e03 = json.loads((FIXTURES / "e03-fixture-manifest.json").read_text())
    selected = json.loads((FIXTURES / "source-documents.json").read_text())
    docs = {
        "paper": {doc["_id"]: doc for doc in selected["papers"]},
        "task": {doc["_id"]: doc for doc in selected["tasks"]},
    }
    items: list[dict[str, Any]] = []
    for section, unit_type, cohort_key in (
        ("papers", "paper", "cohort"),
        ("tasks", "task", "class"),
    ):
        for entry in e03[section]:
            source = docs[unit_type][entry["id"]]
            items.append(
                {
                    "id": entry["id"],
                    "unit_type": unit_type,
                    "cohort": entry[cohort_key],
                    "source_path": f"source-documents.json#/{section}/{entry['id']}",
                    "source_semantic_sha256": semantic_hash(source),
                }
            )
    for entry in e03["adversarial"]:
        rel = Path("adversarial") / f"{entry['id']}.json"
        path = FIXTURES / rel
        if physical_hash(path) != entry["sha256"]:
            raise SystemExit(f"adversarial fixture drift: {entry['id']}")
        source = json.loads(path.read_text())
        items.append(
            {
                "id": entry["id"],
                "unit_type": "adversarial",
                "cohort": entry["kind"],
                "source_path": str(rel),
                "source_physical_sha256": entry["sha256"],
                "source_semantic_sha256": semantic_hash(source),
            }
        )

    if len(items) != 36 or len({item["id"] for item in items}) != 36:
        raise SystemExit("fixture reconciliation failed")
    manifest = {
        "schema_version": "legendary-e05-fixture-manifest/v1",
        "assignment_id": "E05",
        "candidate_id": "candidate-preservation-envelope",
        "frozen_e03_physical_hashes": observed,
        "counts": {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36},
        "items": items,
    }
    write_json(FIXTURES / "manifest.json", manifest)
    print("E05 FIXTURE MANIFEST PASS: 36 exact frozen fixtures")


if __name__ == "__main__":
    main()
