#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
E11 = ROOT / ".omx/state/legendary-experiments/E11"


def load(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E11 VERIFY FAIL: {message}")


e03 = ROOT / ".omx/state/legendary-experiments/E03"
e05 = ROOT / ".omx/state/legendary-experiments/E05"
e07 = ROOT / ".omx/state/legendary-experiments/E07"
e08 = ROOT / ".omx/state/legendary-experiments/E08"
e09 = ROOT / ".omx/state/legendary-experiments/E09"

fixtures = load(E11 / "accessibility-fixtures.json")
goldens = load(E11 / "five-surface-goldens.json")
degradation = load(E11 / "explicit-degradation.json")
next_three = load(E11 / "next-three-assignments.json")
result = load(E11 / "result.json")
source_manifest = load(e03 / "fixture-manifest.json")
thresholds = load(e03 / "thresholds.json")
e07_result = load(e07 / "result.json")
e07_matrix = load(e07 / "surface-matrix.json")
e08_result = load(e08 / "result.json")
e09_result = load(e09 / "result.json")

require(sha256(e03 / "thresholds.json") == fixtures["thresholds_sha256"], "frozen threshold hash drift")
require("E11" in thresholds["frozen_for"], "E03 thresholds are not frozen for E11")
require(sha256(e03 / "fixture-manifest.json") == fixtures["fixture_manifest_sha256"], "fixture manifest hash drift")
require(sha256(e05 / "candidate.json") == fixtures["candidate_provenance"]["candidate_sha256"], "E05 provenance hash drift")
for relative, expected in result["candidate_provenance"]["source_hashes"].items():
    require(sha256(ROOT / ".omx/state/legendary-experiments" / relative) == expected, f"source evidence hash drift: {relative}")

expected_fixtures = []
for kind in ("papers", "tasks", "adversarial"):
    for record in source_manifest[kind]:
        expected_fixtures.append({
            "id": record["id"],
            "kind": kind[:-1] if kind != "adversarial" else "adversarial",
            "sha256": record.get("source_sha256", record.get("sha256")),
        })
require(fixtures["fixtures"] == expected_fixtures, "hashed accessibility fixture set does not exactly match E03")
require(len(expected_fixtures) == fixtures["fixture_count"] == 36, "fixture cardinality is not 36")
require(all(len(item["sha256"]) == 64 for item in expected_fixtures), "fixture missing SHA-256")

require(e07_result["counts"] == {"blocked": 432, "candidates": 3, "cells": 540, "fail": 6, "fixtures": 36, "pass": 102, "surfaces": 5}, "E07 count evidence drift")
require(e08_result["counts"]["rejected_candidates"] == 3, "E08 no longer rejects all candidates")
require(e08_result["verdict"]["quality"] == "REJECT_ALL_ROUND_2_CANDIDATES", "E08 rejection verdict drift")
require(e09_result["verdict"]["winner_selected"] is False, "E09 unexpectedly selected a winner")
require(e09_result["verdict"]["strongest_non_rejected_candidate"] == "E05", "E09 candidate provenance drift")

required_surfaces = {"authenticated_studio", "public_reader", "tui", "real_client_email", "cli_api"}
require({row["surface"] for row in goldens["surfaces"]} == required_surfaces, "five-surface index incomplete")
require(goldens["expected_cells"] == 36 * 5 == 180, "golden cell formula drift")
require(goldens["candidate_is_round_3_winner"] is False, "blocked candidate mislabeled as winner")
require(goldens["accepted_golden_count"] == 0, "goldens fabricated without a winner")
require(all(row["accepted_goldens"] == 0 for row in goldens["surfaces"]), "surface contains fabricated golden")
require(sum(row["observed_round_3_cells"] for row in goldens["surfaces"]) == 180, "source surface reconciliation incomplete")
require(sum(row["observed_status"] == "BLOCKED" for row in goldens["surfaces"]) == 4, "real surface blocks not preserved")
observed = {}
for cell in e07_matrix["cells"]:
    if cell["assignment_id"] == "E05":
        key = (cell["surface"], cell["status"])
        observed[key] = observed.get(key, 0) + 1
require(len([cell for cell in e07_matrix["cells"] if cell["assignment_id"] == "E05"]) == 180, "E05 surface matrix is not 180 cells")
for row in goldens["surfaces"]:
    require(observed.get((row["surface"], row["observed_status"])) == row["observed_round_3_cells"], f"surface evidence drift: {row['surface']}")

require({rule["fixture"] for rule in degradation["rules"]} == {"adv-long-token", "adv-malformed-legacy", "adv-missing-fields"}, "explicit degradation fixtures incomplete")
require(all(rule["status"] == "UNPROVEN_BLOCKED" for rule in degradation["rules"]), "unproven degradation proxy-passed")
require(next_three["complete_round_required"] is True, "complete-three requirement weakened")
require(next_three["next_assignment_ids"] == ["E16", "E17", "E18"], "next complete-three assignment IDs drift")
require(len(next_three["assignments"]) == 3, "next round is not exactly three assignments")

require(result["winner_selected"] is False, "E11 invented a winner")
require(result["verdict"] == {"action": "REWORK", "quality": "NO_WINNER"}, "E11 verdict drift")
require(result["counts"] == {"accepted_goldens": 0, "blocked_real_surfaces": 4, "candidate_specific_source_cells": 180, "fixtures": 36, "next_assignments": 3, "required_golden_cells": 180, "surfaces": 5}, "E11 result counts drift")
for relative, expected in result["artifact_hashes"].items():
    require(sha256(E11 / relative) == expected, f"artifact hash drift: {relative}")

print("E11 VERIFY PASS — REWORK/NO_WINNER")
