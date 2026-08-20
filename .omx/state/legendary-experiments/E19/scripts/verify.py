#!/usr/bin/env python3
"""Verify E19 fail-closed evidence and deterministic double replay."""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

from build import build
from common import CANDIDATE_ID, ROOT, SURFACES, experiment_root, physical_hash


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E19 VERIFY FAIL: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-cells", type=int, default=108)
    parser.add_argument("--require-surfaces", default=",".join(SURFACES))
    parser.add_argument("--require-candidate-provenance", action="store_true")
    args = parser.parse_args()
    require(args.require_cells == 108, "immutable required cell count")
    require(tuple(args.require_surfaces.split(",")) == SURFACES, "immutable required surfaces")

    plan = json.loads((experiment_root("round-06-plan") / "assignments.json").read_text())
    assignment = next(row for row in plan["assignments"] if row["id"] == "E19")
    require(assignment["immutable"] is True, "immutable assignment")

    preflight = json.loads((ROOT / "preflight.json").read_text())
    require(preflight["input_gate_passed"] is True, "frozen input hashes")
    require(preflight["deployment_authorized"] is False, "predeployment stop")
    require(preflight["bounded_probe"]["secrets_persisted"] is False, "no secret persistence")
    require(preflight["bounded_probe"]["production_targets_contacted"] == 0, "no production contact")

    e16 = json.loads((experiment_root("E16") / "result.json").read_text())
    candidate_digest = e16["evidence"]["capsules_sha256"]
    require(preflight["candidate_id"] == CANDIDATE_ID, "candidate id")
    require(preflight["candidate_digest"] == candidate_digest, "candidate digest")

    index = json.loads((ROOT / "capture-index.json").read_text())
    require(index["attempt_count"] == len(index["rows"]) == 108, "exact 108 attempts")
    require(index["accepted_capture_count"] == 0, "zero false captures")
    require(index["missing_cells"] == index["duplicate_cells"] == index["proxy_cells"] == 0, "reconciliation")
    require(len({(row["fixture_id"], row["surface"]) for row in index["rows"]}) == 108, "unique cells")
    require({row["surface"] for row in index["rows"]} == set(SURFACES), "exact surfaces")
    require(len({row["fixture_id"] for row in index["rows"]}) == 36, "exact fixtures")
    for row in index["rows"]:
        path = ROOT / row["path"]
        require(physical_hash(path) == row["attempt_sha256"], f"attempt file hash {row['fixture_id']}/{row['surface']}")
        attempt = json.loads(path.read_text())
        require(attempt["candidate_digest"] == candidate_digest, "identical candidate digest")
        require(attempt["deployment_id"] is None, "no fabricated deployment id")
        require(attempt["attempt_status"] == "BLOCKED" and attempt["accepted_capture"] is False, "blocked attempt")
        require(attempt["capture_sha256"] is None and attempt["explicit_error"], "explicit error no capture")
        require(attempt["silent_blank"] is False and attempt["proxy_derived"] is False, "no blank or proxy")
        require(attempt["production_contacted"] is False, "no production contact")

    rollback = json.loads((ROOT / "rollback.json").read_text())
    require(rollback["fixture_records_removed_or_restored"] == 36, "rollback 36/36")
    require(rollback["rollback_coverage_percent"] == 100 and rollback["deployment_torn_down"] is True, "rollback and teardown")
    require(rollback["production_mutations"] == 0 and rollback["secrets_persisted"] is False, "safe boundary")
    result = json.loads((ROOT / "result.json").read_text())
    require(result["verdict"] == {
        "quality": "BLOCKED",
        "action": "REWORK",
        "winner_selected": False,
        "pilot_authorized": False,
        "real_surface_gate_passed": False,
    }, "fail-closed verdict")

    names = (
        "deployment-manifest.json", "session-manifest.json", "provenance-manifest.json",
        "capture-index.json", "rollback.json", "hard-gates.json", "result.json",
    )
    with tempfile.TemporaryDirectory(prefix="e19-double-replay-") as tmp:
        first, second = Path(tmp) / "first", Path(tmp) / "second"
        build(first)
        build(second)
        for name in names:
            require((first / name).read_bytes() == (second / name).read_bytes(), f"double replay {name}")
            require((first / name).read_bytes() == (ROOT / name).read_bytes(), f"frozen output {name}")
        for row in index["rows"]:
            require((first / row["path"]).read_bytes() == (second / row["path"]).read_bytes(), f"attempt replay {row['path']}")

    print("E19 REPLAY PASS verdict=BLOCKED captures=0 attempts=108 rollback=36/36")


if __name__ == "__main__":
    main()
