#!/usr/bin/env python3
"""Fail-closed verification for E21."""

from __future__ import annotations

import json
from pathlib import Path

from build import ROOT, physical_hash


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E21 VERIFY FAIL: {message}")


def load(name: str):
    return json.loads((ROOT / name).read_text())


def main() -> None:
    replay = load("replay-hashes.json")
    require(replay["byte_stable"] is True, "two byte-stable replays")
    require(replay["pass_1"] == replay["pass_2"], "replay hashes identical")
    for relative, expected in replay["pass_1"].items():
        require(physical_hash(ROOT / relative) == expected, f"canonical hash {relative}")

    reconciliation = load("cell-reconciliation.json")
    counts = reconciliation["counts"]
    require(counts == {"accepted": 0, "blocked": 180, "expected": 180, "proxy_or_backfill": 0, "reconciled": 180}, "180 blocked cells reconciled")
    rows = reconciliation["rows"]
    require(len({(row["fixture_id"], row["surface"]) for row in rows}) == 180, "180 unique fixture/surface cells")
    require(all(row["status"] == "BLOCKED" and not row["accepted_candidate_specific_capture"] for row in rows), "no blocked cell promoted")
    require(all(row["source_record_sha256"] and row["provenance"] for row in rows), "hash and provenance retained")

    adversarial = load("adversarial-accounting.json")
    require(adversarial["accounted_fixtures"] == adversarial["expected_fixtures"] == 6, "six adversarial fixtures")
    require(adversarial["accounted_cells"] == adversarial["expected_cells"] == 30, "thirty adversarial cells")
    require(all(row["reconciled_surfaces"] == 5 and row["accepted"] == 0 and row["blocked"] == 5 for row in adversarial["rows"]), "adversarial cells blocked honestly")

    quarantine = load("rollback-quarantine.json")
    blocked = quarantine["blocked_or_rejected_units"]
    require(blocked["quarantined"] == blocked["expected"] == 180 and blocked["coverage_percent"] == 100, "quarantine 180/180")
    require(quarantine["production_mutations"] == 0 and quarantine["aggregate_override_used"] is False, "no mutation or override")

    matrix = load("gate-matrix.json")
    require(matrix["gates"]["E19_dependency"] == "BLOCKED" and matrix["gates"]["E20_dependency"] == "BLOCKED", "dependencies blocked")
    require(matrix["dependency_gate_passed"] is False, "pre-seal dependency gate failed closed")
    require(matrix["blind_scoring_seal_created"] is False and matrix["scoring_executed"] is False, "no seal or scoring")
    require(matrix["verdict"] == {"action": "REWORK", "quality": "BLOCKED"}, "gate verdict")

    result = load("result.json")
    decision = result["decision"]
    require(decision["quality"] == "BLOCKED" and decision["action"] == "REWORK", "result verdict")
    require(decision["winner_selected"] is False and decision["pilot_authorized"] is False, "no winner or pilot")
    require(decision["blind_scoring_seal_created"] is False and decision["scoring_executed"] is False, "no result seal or scoring")
    require(result["counts"]["production_mutations"] == 0, "no production mutation")
    require(not (ROOT / "blind-seal.json").exists() and not (ROOT / "scorecard.json").exists(), "forbidden seal and scorecard absent")

    print("E21 VERIFY PASS verdict=BLOCKED/REWORK cells=180 accepted=0 adversarial=6/6 quarantined=180/180 winner=false pilot=false seal=false scoring=false")


if __name__ == "__main__":
    main()
