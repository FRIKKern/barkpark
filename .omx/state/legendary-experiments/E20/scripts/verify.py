#!/usr/bin/env python3
"""Verify E20 fail-closed evidence and byte-stable double replay."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from build import build
from common import ROOT, SURFACES, experiment, physical_hash, read_json


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E20 VERIFY FAIL: {message}")


def main() -> None:
    plan_path = experiment("round-06-plan") / "assignments.json"
    plan = read_json(plan_path)
    assignment = next(row for row in plan["assignments"] if row["id"] == "E20")
    require(assignment["immutable"] is True and assignment["depends_on"] == ["E19"], "immutable dependency")

    preflight = read_json(ROOT / "preflight.json")
    require(preflight["dependency_gate_passed"] is False, "dependency must remain blocked")
    require(preflight["e19_quality"] == "BLOCKED", "E19 quality pin")
    require(preflight["deployment_id"] is None and preflight["deployment_created"] is False, "no deployment")
    require(preflight["pins"]["plan_sha256"] == physical_hash(plan_path), "plan hash pin")
    for name, key in (("result.json", "e19_result_sha256"), ("deployment-manifest.json", "e19_deployment_sha256"), ("provenance-manifest.json", "e19_provenance_sha256")):
        require(preflight["pins"][key] == physical_hash(experiment("E19") / name), f"E19 pin {name}")

    index = read_json(ROOT / "capture-index.json")
    require(index["cell_count"] == len(index["rows"]) == 72, "exact 72 cells")
    require(index["not_started_cells"] == 72 and index["accepted_capture_count"] == 0, "all cells not started")
    require(index["missing_cells"] == index["duplicate_cells"] == index["proxy_cells"] == 0, "cell reconciliation")
    require(len({(row["fixture_id"], row["surface"]) for row in index["rows"]}) == 72, "unique cells")
    require({row["surface"] for row in index["rows"]} == set(SURFACES), "exact surfaces")
    require(len({row["fixture_id"] for row in index["rows"]}) == 36, "exact fixtures")
    for row in index["rows"]:
        path = ROOT / row["path"]
        require(physical_hash(path) == row["cell_sha256"], f"cell hash {row['fixture_id']}/{row['surface']}")
        cell = read_json(path)
        require(cell["status"] == "NOT_STARTED" and cell["accepted_capture"] is False, "not-started cell")
        require(cell["capture_sha256"] is None and cell["explicit_block"], "explicit block no capture")
        require(cell["silent_blank"] is False and cell["proxy_evidence"] is False, "no blank or proxy")
        require(cell["delivery_receipt"] is None and cell["client_open_timestamp"] is None, "no fake email proof")
        require(cell["production_contacted"] is False, "no production contact")

    rollback = read_json(ROOT / "rollback.json")
    require(rollback["fixture_records_untouched"] == rollback["fixture_records_expected"] == 36, "untouched 36/36")
    require(rollback["rollback_coverage_percent"] == 100, "rollback accounting")
    require(rollback["production_mutations"] == 0 and rollback["secrets_persisted"] is False, "safe boundary")
    result = read_json(ROOT / "result.json")
    require(result["verdict"] == {"quality": "BLOCKED", "action": "REWORK", "real_surface_gate_passed": False, "winner_selected": False, "pilot_authorized": False}, "fail-closed verdict")

    names = ("preflight.json", "tui-session-manifest.json", "delivery-manifest.json", "capture-index.json", "rollback.json", "hard-gates.json", "result.json")
    with tempfile.TemporaryDirectory(prefix="e20-double-replay-") as tmp:
        first, second = Path(tmp) / "first", Path(tmp) / "second"
        build(first)
        build(second)
        for name in names:
            require((first / name).read_bytes() == (second / name).read_bytes(), f"double replay {name}")
            require((first / name).read_bytes() == (ROOT / name).read_bytes(), f"frozen output {name}")
        for row in index["rows"]:
            require((first / row["path"]).read_bytes() == (second / row["path"]).read_bytes(), f"cell replay {row['path']}")

    print("E20 REPLAY PASS verdict=BLOCKED cells=72 accepted=0 proxies=0")


if __name__ == "__main__":
    main()
