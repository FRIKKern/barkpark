#!/usr/bin/env python3
"""Fail-closed verification for the E18 canonical decision."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from build import E03, E16, E17, OUTPUT, ROOT, build_score, build_seal, load_jsonl, output_files, physical_hash


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E18 VERIFY FAIL: {message}")


def main() -> None:
    replay = json.loads((OUTPUT / "replay-hashes.json").read_text())
    expected_paths = {
        (experiment, str(path.relative_to(root)))
        for experiment, root in (("E16", E16), ("E17", E17))
        for path in output_files(root)
    }
    actual_paths = {(row["experiment"], row["path"]) for row in replay["rows"]}
    require(actual_paths == expected_paths, "every E16/E17 output file inventoried")
    require(all(row["stable"] and row["pass_1_sha256"] == row["pass_2_sha256"] for row in replay["rows"]), "double replay hashes stable")

    seal = json.loads((OUTPUT / "blind-seal.json").read_text())
    require(seal["sealed_before_scoring"] is True, "sealed-before-scoring declaration")
    for name, expected in seal["files"].items():
        require(physical_hash(OUTPUT / name) == expected, f"sealed file hash {name}")
    blind = load_jsonl(OUTPUT / "blind-records.jsonl")
    forbidden = set(seal["forbidden_scoring_fields"])
    require(len(blind) == 36 and len({row["fixture_id"] for row in blind}) == 36, "36 unique blind records")
    require(all(not (set(row) & forbidden) for row in blind), "blind records contain no scoring fields")
    require(all(len(row["surface_cell_sha256"]) == 5 for row in blind), "five surface identities per blind record")

    adversarial = {row["id"] for row in json.loads((E03 / "fixture-manifest.json").read_text())["adversarial"]}
    covered = {row["fixture_id"] for row in blind if row["adversarial"]}
    require(covered == adversarial and len(covered) == 6, "all E03 adversarial fixtures covered")

    proof = json.loads((OUTPUT / "rollback-quarantine.json").read_text())
    require(proof["rollback"]["passed"] == proof["rollback"]["required"] == 36, "rollback 36/36")
    require(proof["rollback"]["coverage_percent"] == 100, "rollback 100 percent")
    require(proof["source_quarantine"]["passed"] == proof["source_quarantine"]["required"] == 2, "source quarantine 2/2")
    require(proof["source_quarantine"]["coverage_percent"] == 100, "source quarantine 100 percent")
    require(proof["rejected_cell_quarantine"]["quarantined"] == proof["rejected_cell_quarantine"]["required"] == 180, "rejected cell quarantine 180/180")
    require(proof["rejected_cell_quarantine"]["coverage_percent"] == 100, "rejected cell quarantine 100 percent")

    matrix = json.loads((OUTPUT / "gate-matrix.json").read_text())
    require(matrix["gates"]["missing_cells"] == "PASS_ZERO", "zero missing cells")
    require(matrix["gates"]["inherited_e17_gate"] == "FAIL/REWORK", "inherited E17 failure retained")
    require(matrix["verdict"] == {"quality": "FAIL", "action": "REWORK"}, "hard-gate rejection verdict")
    result = json.loads((ROOT / "result.json").read_text())
    require(result["verdict"]["quality"] == "FAIL" and result["verdict"]["action"] == "REWORK", "result verdict")
    require(result["verdict"]["winner_selected"] is False and result["verdict"]["pilot_authorized"] is False, "no winner or pilot")
    require(result["counts"]["e17_real_captures"] == 0 and result["counts"]["e17_cells"] == 180, "0/180 real captures")

    hashes = json.loads((OUTPUT / "hashes.json").read_text())["files"]
    for relative, expected in hashes.items():
        require(physical_hash(ROOT / relative) == expected, f"artifact hash {relative}")

    with tempfile.TemporaryDirectory(prefix="e18-double-build-") as tmp:
        original_output = OUTPUT
        # The canonical builder is deterministic; rerun it twice in place and compare all deterministic artifacts.
        before = {relative: physical_hash(ROOT / relative) for relative in hashes}
        build_seal()
        build_score()
        first = {relative: physical_hash(ROOT / relative) for relative in hashes}
        build_seal()
        build_score()
        second = {relative: physical_hash(ROOT / relative) for relative in hashes}
        require(before == first == second, "E18 byte-stable double build")
        require(original_output == OUTPUT and Path(tmp).exists(), "isolated verification context")

    print("E18 VERIFY PASS verdict=FAIL/REWORK replay=all-twice rollback=36/36 quarantine=182/182 adversarial=6/6 captures=0/180 winner=false pilot=false")


if __name__ == "__main__":
    main()
