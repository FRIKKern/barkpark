#!/usr/bin/env python3
"""Replay E03 integrity, count, provenance, and result-contract checks."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    manifest = json.loads((ROOT / "fixture-manifest.json").read_text())
    matrix = json.loads((ROOT / "surface-matrix.json").read_text())
    scores = json.loads((ROOT / "baseline-scores.json").read_text())
    result = json.loads((ROOT / "result.json").read_text())
    raw_index = json.loads((ROOT / "raw-capture-index.json").read_text())
    assert manifest["counts"] == {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36}
    assert len({row["id"] for row in manifest["papers"]}) == 12
    assert len({row["id"] for row in manifest["tasks"]}) == 18
    assert len({row["class"] for row in manifest["tasks"]}) == 6
    assert manifest["reconciliation"]["overlap_count"] == 0
    assert matrix["fixture_count"] == 36 and matrix["surface_count"] == 5 and matrix["cell_count"] == 180
    assert len(matrix["cells"]) == 180
    assert not any(row["surface"] in {"Studio", "email"} and row["status"] == "PASS" for row in matrix["cells"])
    assert len(scores["paper_scores"]) == 12 and len(scores["task_scores"]) == 18
    for row in manifest["adversarial"]:
        assert sha(ROOT / row["path"]) == row["sha256"]
    assert sha(ROOT / manifest["selected_raw"]["path"]) == manifest["selected_raw"]["sha256"]
    for row in raw_index["files"]:
        path = ROOT / row["path"]
        assert path.stat().st_size == row["bytes"] and sha(path) == row["sha256"]
    for path in (ROOT / "raw").rglob("*"):
        if path.is_file():
            payload = path.read_bytes()
            assert b"set-cookie: _barkpark_key=" not in payload
            assert b'<meta name="csrf-token" content="I' not in payload
    for name, expected in result["artifact_hashes"].items():
        assert sha(ROOT / name) == expected, name
    assert all(row["status"] == "PASS" for row in result["hard_gate_outcomes"])
    assert result["verdict"] == {"quality": "PARTIAL", "action": "REWORK"}
    assert result["counts"]["distinct_probes"] == 64
    print("E03 VERIFY PASS")
    print("fixtures=36 papers=12 tasks=18 adversarial=6 cells=180 probes=64")
    print(f"fixture_manifest_sha256={sha(ROOT / 'fixture-manifest.json')}")
    print(f"result_sha256={sha(ROOT / 'result.json')}")


if __name__ == "__main__":
    main()
