#!/usr/bin/env python3
"""Build the deterministic 36 x 5 reconciliation from frozen real attempts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from common import CANDIDATE_ID, ROOT, SURFACES, e11_root, load_capsules, physical_hash, semantic_hash, write_json


def build(output: Path) -> None:
    capsules = sorted(load_capsules(), key=lambda row: row["fixture_id"])
    attempts = json.loads((ROOT / "attempt-index.json").read_text())
    attempt_lookup = {(row["fixture_id"], row["surface"]): row for row in attempts["rows"]}
    e11_fixtures = json.loads((e11_root() / "accessibility-fixtures.json").read_text())
    e11_lookup = {row["id"]: row for row in e11_fixtures["fixtures"]}
    cells: list[dict[str, Any]] = []

    for capsule in capsules:
        fixture_id = capsule["fixture_id"]
        for surface in SURFACES:
            attempt = attempt_lookup[(fixture_id, surface)]
            raw_path = ROOT / attempt["raw_path"]
            raw = json.loads(raw_path.read_text())
            cell = {
                "schema_version": "legendary-e17-cell/v1",
                "candidate_id": CANDIDATE_ID,
                "fixture_id": fixture_id,
                "fixture_kind": capsule["unit_type"],
                "fixture_sha256": e11_lookup[fixture_id]["sha256"],
                "candidate_source_sha256": capsule["source_sha256"],
                "surface": surface,
                "attempt_sha256": physical_hash(raw_path),
                "capture_status": "BLOCKED",
                "capture_sha256": None,
                "silent_blank": False,
                "silent_blank_claim_boundary": "NO_CAPTURE_EXISTS; ONLY_EXPLICIT_BLOCK_RECORDED",
                "narrow_width_degradation": "UNPROVEN",
                "block_reason": raw["block_reason"],
            }
            cell["cell_sha256"] = semantic_hash(cell)
            cells.append(cell)

    output.mkdir(parents=True, exist_ok=True)
    (output / "cells.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in cells))
    surface_rows = []
    for surface in SURFACES:
        rows = [row for row in cells if row["surface"] == surface]
        surface_rows.append({
            "surface": surface,
            "cells": len(rows),
            "attempts": len(rows),
            "accepted_captures": sum(row["capture_sha256"] is not None for row in rows),
            "blocked": sum(row["capture_status"] == "BLOCKED" for row in rows),
            "status": "FAIL",
        })
    write_json(output / "reconciliation.json", {
        "schema_version": "legendary-e17-reconciliation/v1",
        "candidate_id": CANDIDATE_ID,
        "formula": "36 fixtures x 5 real surfaces = 180 cells",
        "fixtures": len(capsules),
        "surfaces": len(SURFACES),
        "cells": len(cells),
        "attempt_artifacts": len(cells),
        "accepted_captures": 0,
        "missing_cells": 0,
        "duplicate_cells": len(cells) - len({(row["fixture_id"], row["surface"]) for row in cells}),
        "surface_rows": surface_rows,
    })
    write_json(output / "hard-gates.json", {
        "schema_version": "legendary-e17-hard-gates/v1",
        "outcomes": {
            "exact_180_candidate_specific_captures": "FAIL_0_OF_180",
            "authenticated_studio": "FAIL_AUTH_SESSION_AND_DEPLOYMENT_BLOCK",
            "public_reader": "FAIL_NO_DEPLOYED_E16_PROVENANCE",
            "tui": "FAIL_SCHEMA_LOAD_BEFORE_SELECTION",
            "real_client_email": "FAIL_ENDPOINT_404_NO_MESSAGE_IMPORTED",
            "cli_api": "FAIL_CANDIDATE_ABSENT",
            "zero_silent_blanks": "PARTIAL_EXPLICIT_BLOCKS_180_OF_180_BUT_NO_CAPTURE_PROOF",
            "explicit_narrow_width_degradation": "FAIL_UNPROVEN_REAL_TUI_AND_EMAIL",
            "proxy_source_synthetic_substitutions": "PASS_ZERO_PROMOTED",
        },
        "verdict": {"quality": "FAIL", "action": "REWORK"},
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "output")
    args = parser.parse_args()
    build(args.output)
    print(f"E17 BUILD PASS output={args.output} cells=180 attempts=180 captures=0")


if __name__ == "__main__":
    main()
