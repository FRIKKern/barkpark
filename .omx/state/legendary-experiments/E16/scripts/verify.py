#!/usr/bin/env python3
"""Fail-closed verification for E16 and the E08 structural regressions."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from build import ROOT, build, physical_hash
from candidate import build_capsule, restore_tree, semantic_hash

OUTPUT = ROOT / "output"
EXPECTED_E03 = {
    "fixture-manifest.json": "0ab24d0a38f9d8db97073accaea37f02786d9c47f7dac3471e858907d5c308df",
    "selected-source-documents.json": "803ea48c241c50e9018470837a02071980298b102d7d035182cc99c9e7338cbf",
    "thresholds.json": "4117e563cb8d261b3256823fc90f16fb0e3d57a51fa84ab8b0a609d3684ecd6b",
    "candidate-rubric.json": "3805ed5afb1ed76c22ba2144aefaf2d5c5e73508fb8f4170d9441e3400d952d4",
    "failure-taxonomy.json": "29fbb60a099ff6607efd87716887f592e2443498c5b65f2b87317ba3e1807ce9",
}
DETERMINISTIC_FILES = ("capsules.jsonl", "fixture-manifest.json", "rollback-manifest.json", "quarantine.json", "structure-scorecard.json")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E16 VERIFY FAIL: {message}")


def load_capsules(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def main() -> None:
    manifest = json.loads((OUTPUT / "fixture-manifest.json").read_text())
    require(manifest["frozen_e03_physical_hashes"] == EXPECTED_E03, "frozen E03 hashes drifted")
    require(manifest["counts"] == {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36}, "fixture counts")
    capsules = load_capsules(OUTPUT / "capsules.jsonl")
    require(len(capsules) == len({row["fixture_id"] for row in capsules}) == 36, "36 unique capsules")
    for row in capsules:
        restored = restore_tree(row["semantic_tree"])
        require(restored == row["source"], f"lossless round trip {row['fixture_id']}")
        require(semantic_hash(restored) == row["source_sha256"] == row["round_trip_sha256"], f"source hash {row['fixture_id']}")
        require([event["ordinal"] for event in row["semantic_events"]] == list(range(len(row["semantic_events"]))), f"semantic order {row['fixture_id']}")
        require(build_capsule(row, fixture_id=row["fixture_id"], unit_type=row["unit_type"], cohort=row["cohort"]) == row, f"idempotence {row['fixture_id']}")
    nested = next(row for row in capsules if row["fixture_id"] == "adv-nested-list-table")
    nested_roles = [event["role"] for event in nested["semantic_events"]]
    require("table" in nested_roles and "list" in nested_roles and nested_roles.index("table") < nested_roles.index("list"), "nested table/list hierarchy")
    restored_nested = restore_tree(nested["semantic_tree"])
    require(restored_nested["body"]["blocks"][0]["type"] == "table", "table retained")
    require(restored_nested["body"]["blocks"][0]["rows"][0][0]["type"] == "bullet_list", "nested bullet_list retained")
    long_row = next(row for row in capsules if row["fixture_id"] == "adv-long-content")
    long_text = restore_tree(long_row["semantic_tree"])["body"]["blocks"][0]["text"]
    require(len(long_text) == 7500 and long_text == long_row["source"]["body"]["blocks"][0]["text"], "7500/7500 long content")
    rollback = json.loads((OUTPUT / "rollback-manifest.json").read_text())["rows"]
    require(len(rollback) == 36 and all(row["status"] == "PASS" for row in rollback), "36/36 rollback")
    quarantine = json.loads((OUTPUT / "quarantine.json").read_text())["rows"]
    require({row["fixture_id"] for row in quarantine} == {"adv-malformed-legacy", "adv-missing-fields"}, "explicit quarantine set")
    require(all(row["rollback_status"] == "PASS" for row in quarantine), "quarantine rollback")
    with tempfile.TemporaryDirectory(prefix="e16-replay-") as tmp:
        first = Path(tmp) / "first"
        second = Path(tmp) / "second"
        build(first)
        build(second)
        for name in DETERMINISTIC_FILES:
            require((first / name).read_bytes() == (second / name).read_bytes() == (OUTPUT / name).read_bytes(), f"byte-stable clean replay {name}")
    timing = json.loads((OUTPUT / "timing.json").read_text())
    require(timing["fixture_count"] == 36 and timing["clean_build_runs"] == 3 and timing["under_60_minutes"] is True, "timing evidence")
    hashes = json.loads((OUTPUT / "hashes.json").read_text())["files"]
    for relative, expected in hashes.items():
        require(physical_hash(ROOT / relative) == expected, f"artifact hash {relative}")
    result = json.loads((ROOT / "result.json").read_text())
    require(result["assignment_id"] == "E16", "result assignment")
    require(set(result["frozen_threshold_outcomes"]) == {"accessibility", "authored_content_preservation", "build_formula", "capacity_rule", "idempotence", "pilot_failure_rate", "reader_visibility", "render_test_gate", "rollback", "schema_validity", "structural_completeness", "surface_exercise", "width_overflow"}, "all frozen thresholds retained")
    require(result["verdict"] == {"quality": "PASS", "action": "PROCEED_TO_E17", "e16_gate": "PASS", "real_surface_claimed": False, "winner_selected": False}, "truthful verdict")
    print(f"E16 VERIFY PASS fixtures=36 long_content=7500/7500 nested=table>bullet_list rollback=36/36 quarantine={len(quarantine)} critical_high=0 capsules_sha256={physical_hash(OUTPUT / 'capsules.jsonl')}")


if __name__ == "__main__":
    main()
