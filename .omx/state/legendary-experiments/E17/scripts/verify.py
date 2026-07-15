#!/usr/bin/env python3
"""Fail-closed E17 verification, including clean deterministic double replay."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from build import build
from common import CANDIDATE_ID, ROOT, SURFACES, e11_root, e16_root, physical_hash


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E17 VERIFY FAIL: {message}")


def main() -> None:
    e11_assignments = json.loads((e11_root() / "next-three-assignments.json").read_text())
    e17 = next(row for row in e11_assignments["assignments"] if row["id"] == "E17")
    require(e17["gate"].startswith("Produce 180 hashed candidate-specific captures"), "exact E11 gate")
    e16 = json.loads((e16_root() / "result.json").read_text())
    require(e16["candidate_id"] == CANDIDATE_ID, "accepted E16 candidate")

    attempt_index = json.loads((ROOT / "attempt-index.json").read_text())
    require(attempt_index["attempt_count"] == 180 and attempt_index["capture_count"] == 0, "attempt index counts")
    require(len(attempt_index["rows"]) == 180, "180 indexed attempt rows")
    for row in attempt_index["rows"]:
        raw_path = ROOT / row["raw_path"]
        require(physical_hash(raw_path) == row["attempt_sha256"], f"attempt hash {row['fixture_id']}/{row['surface']}")
        raw = json.loads(raw_path.read_text())
        require(raw["accepted_capture"] is False and raw["capture_sha256"] is None, "no false capture promotion")
        require(raw["candidate_materialized"] is False, "candidate materialization boundary")

    cells = [json.loads(line) for line in (ROOT / "output" / "cells.jsonl").read_text().splitlines() if line]
    keys = {(row["fixture_id"], row["surface"]) for row in cells}
    require(len(cells) == len(keys) == 180, "exact unique 36 x 5 cells")
    require({row["surface"] for row in cells} == set(SURFACES), "five exact real surfaces")
    require(len({row["fixture_id"] for row in cells}) == 36, "36 exact fixtures")
    require(all(row["capture_status"] == "BLOCKED" and row["capture_sha256"] is None for row in cells), "all cells fail closed")
    require(all(row["silent_blank"] is False for row in cells), "every cell records explicit block not silent blank")

    reconciliation = json.loads((ROOT / "output" / "reconciliation.json").read_text())
    require(reconciliation["cells"] == 180 and reconciliation["missing_cells"] == 0, "cell reconciliation")
    require(reconciliation["accepted_captures"] == 0 and reconciliation["duplicate_cells"] == 0, "capture and duplicate reconciliation")
    gates = json.loads((ROOT / "output" / "hard-gates.json").read_text())
    require(gates["verdict"] == {"quality": "FAIL", "action": "REWORK"}, "hard-gate verdict")
    require(gates["outcomes"]["explicit_narrow_width_degradation"].startswith("FAIL"), "narrow-width failure is explicit")
    result = json.loads((ROOT / "result.json").read_text())
    require(result["verdict"] == {
        "quality": "FAIL",
        "action": "REWORK",
        "winner_selected": False,
        "pilot_authorized": False,
        "real_surface_gate_passed": False,
    }, "truthful final verdict")

    hashes = json.loads((ROOT / "output" / "hashes.json").read_text())
    require(hashes["file_count"] == 191, "191 deterministic hashed files")
    for relative, expected in hashes["files"].items():
        require(physical_hash(ROOT / relative) == expected, f"artifact hash {relative}")

    with tempfile.TemporaryDirectory(prefix="e17-double-replay-") as tmp:
        first = Path(tmp) / "first"
        second = Path(tmp) / "second"
        build(first)
        build(second)
        for name in ("cells.jsonl", "reconciliation.json", "hard-gates.json"):
            require((first / name).read_bytes() == (second / name).read_bytes(), f"double replay {name}")
            require((first / name).read_bytes() == (ROOT / "output" / name).read_bytes(), f"frozen output {name}")

    print("E17 REPLAY PASS verdict=FAIL/REWORK captures=0 attempts=180")


if __name__ == "__main__":
    main()
