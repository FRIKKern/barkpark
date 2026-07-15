#!/usr/bin/env python3
"""Build the canonical E07 five-surface adversarial evidence matrix."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent
E03 = EXPERIMENTS / "E03"
SURFACES = ["authenticated_studio", "public_reader", "tui", "cli_api", "real_client_email"]
CANDIDATES = [
    ("E04", "candidate-canonical-native"),
    ("E05", "candidate-preservation-envelope"),
    ("E06", "candidate-cohort-rails"),
]


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha(path: Path) -> str:
    return sha_bytes(path.read_bytes())


def load(path: Path) -> Any:
    return json.loads(path.read_text())


def write(name: str, value: object) -> None:
    path = ROOT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


def frozen_fixtures() -> list[dict[str, str]]:
    manifest = load(E03 / "fixture-manifest.json")
    rows = [
        {"id": row["id"], "kind": "paper", "source_sha256": row["source_sha256"]}
        for row in manifest["papers"]
    ]
    rows += [
        {"id": row["id"], "kind": "task", "source_sha256": row["source_sha256"]}
        for row in manifest["tasks"]
    ]
    rows += [
        {"id": row["id"], "kind": "adversarial", "source_sha256": row["sha256"]}
        for row in manifest["adversarial"]
    ]
    assert len(rows) == 36 and len({(row["kind"], row["id"]) for row in rows}) == 36
    return rows


def coverage() -> dict[str, dict[tuple[str, str], dict[str, str]]]:
    result: dict[str, dict[tuple[str, str], dict[str, str]]] = {}

    e04 = load(EXPERIMENTS / "E04/transformation-manifest.json")["units"]
    result["E04"] = {
        (row["kind"], row["id"]): {
            "outcome": row["status"],
            "evidence": "../E04/transformation-manifest.json",
            "evidence_sha256": sha(EXPERIMENTS / "E04/transformation-manifest.json"),
        }
        for row in e04
    }

    e05_path = EXPERIMENTS / "E05/outputs/envelopes.jsonl"
    e05_rows = [json.loads(line) for line in e05_path.read_text().splitlines() if line.strip()]
    frozen_kinds = {row["id"]: row["kind"] for row in frozen_fixtures()}
    result["E05"] = {
        (frozen_kinds[row["fixture_id"]], row["fixture_id"]): {
            "outcome": row.get("reader_contract", {}).get("status", "explicit_envelope"),
            "evidence": "../E05/outputs/envelopes.jsonl",
            "evidence_sha256": sha(e05_path),
        }
        for row in e05_rows
    }

    e06_path = EXPERIMENTS / "E06/dispatch-manifest.json"
    e06_rows = load(e06_path)["decisions"]
    result["E06"] = {
        (row["kind"], row["id"]): {
            "outcome": row["outcome"],
            "evidence": "../E06/dispatch-manifest.json",
            "evidence_sha256": sha(e06_path),
        }
        for row in e06_rows
    }
    return result


def main() -> None:
    started = time.perf_counter()
    fixtures = frozen_fixtures()
    candidate_coverage = coverage()
    cells: list[dict[str, Any]] = []

    blocked_reasons = {
        "authenticated_studio": "no authenticated Studio credentials or candidate-specific Studio capture",
        "public_reader": "candidates were not materialized on a public reader; E03 source probes cannot proxy candidate proof",
        "tui": "no deterministic candidate-specific TUI render capture at narrow widths",
        "real_client_email": "no delivery account and no real-client email render capture",
    }

    for assignment_id, candidate_id in CANDIDATES:
        local = candidate_coverage[assignment_id]
        for fixture in fixtures:
            key = (fixture["kind"], fixture["id"])
            for surface in SURFACES:
                base = {
                    "assignment_id": assignment_id,
                    "candidate_id": candidate_id,
                    "fixture_id": fixture["id"],
                    "fixture_kind": fixture["kind"],
                    "fixture_source_sha256": fixture["source_sha256"],
                    "surface": surface,
                }
                if surface != "cli_api":
                    cells.append({**base, "status": "BLOCKED", "reason": blocked_reasons[surface], "candidate_specific_capture": False})
                elif key in local:
                    evidence = local[key]
                    cells.append({**base, "status": "PASS", "reason": "candidate emits an explicit local output, quarantine, or exclusion record", "candidate_specific_capture": True, **evidence})
                else:
                    cells.append({**base, "status": "FAIL", "reason": "candidate has no output or explicit rejection record for this frozen fixture", "candidate_specific_capture": False})

    scorecards = []
    for assignment_id, candidate_id in CANDIDATES:
        own = [row for row in cells if row["assignment_id"] == assignment_id]
        counts = {status.lower(): sum(row["status"] == status for row in own) for status in ("PASS", "FAIL", "BLOCKED")}
        surface_counts = {
            surface: {status.lower(): sum(row["surface"] == surface and row["status"] == status for row in own) for status in ("PASS", "FAIL", "BLOCKED")}
            for surface in SURFACES
        }
        scorecards.append({
            "assignment_id": assignment_id,
            "candidate_id": candidate_id,
            "fixture_count": 36,
            "cell_count": len(own),
            "counts": counts,
            "surface_counts": surface_counts,
            "hard_gate": "REJECTED",
            "verdict": "BLOCKED_REWORK",
            "reasons": [
                "four target surfaces lack candidate-specific replayable evidence",
                *(["six E03 adversarial fixtures lack any E06 candidate output or explicit rejection record"] if assignment_id == "E06" else []),
            ],
        })

    thresholds = load(E03 / "thresholds.json")["thresholds"]
    outcomes = {
        key: (
            "BLOCKED" if key in {"accessibility", "reader_visibility", "surface_exercise", "width_overflow"}
            else "NOT_PROVEN_BY_E07" if key in {"authored_content_preservation", "idempotence", "rollback", "schema_validity", "structural_completeness", "render_test_gate"}
            else "NOT_APPLICABLE_ROUND_3_ATTACK"
        )
        for key in thresholds
    }
    outcomes["surface_exercise"] = "FAIL_432_BLOCKED_CELLS"
    outcomes["reader_visibility"] = "FAIL_NO_CANDIDATE_SPECIFIC_STUDIO_PUBLIC_TUI_OR_EMAIL_CAPTURE"
    outcomes["width_overflow"] = "BLOCKED_NO_TUI_OR_REAL_EMAIL_NARROW_WIDTH_CAPTURE"

    roster = {
        "schema_version": "legendary-e07-attack-roster/v1",
        "assignment_id": "E07",
        "round": 3,
        "fixture_count": len(fixtures),
        "candidate_count": len(CANDIDATES),
        "surface_count": len(SURFACES),
        "expected_cell_count": len(fixtures) * len(CANDIDATES) * len(SURFACES),
        "fixtures": fixtures,
        "candidates": [{"assignment_id": a, "candidate_id": c, "result_sha256": sha(EXPERIMENTS / f"{a}/result.json")} for a, c in CANDIDATES],
        "frozen_inputs": {
            "fixture_manifest_sha256": sha(E03 / "fixture-manifest.json"),
            "thresholds_sha256": sha(E03 / "thresholds.json"),
            "failure_taxonomy_sha256": sha(E03 / "failure-taxonomy.json"),
        },
        "surfaces": SURFACES,
        "attack_axes": ["authentication and visibility", "blank versus explicit failure", "narrow width and overflow", "email delivery and real-client rendering", "source-to-render traceability"],
    }
    matrix = {
        "schema_version": "legendary-e07-surface-matrix/v1",
        "assignment_id": "E07",
        "cell_count": len(cells),
        "status_counts": {status.lower(): sum(row["status"] == status for row in cells) for status in ("PASS", "FAIL", "BLOCKED")},
        "cells": cells,
    }
    rejections = {
        "schema_version": "legendary-e07-rejection-evidence/v1",
        "assignment_id": "E07",
        "hard_gate": "A candidate is rejected if any target surface is unexercised, silently blank, clips authored content, or lacks replayable evidence.",
        "rejected_candidates": [row["candidate_id"] for row in scorecards],
        "capability_blocks": [
            "authenticated Studio credentials and candidate-specific captures unavailable",
            "real-client email delivery and render captures unavailable",
            "candidate-specific public reader materialization unavailable",
            "candidate-specific TUI narrow-width capture unavailable",
        ],
        "proxy_evidence_rejected": [
            "E03 source-surface probes do not prove transformed E04/E05/E06 candidate rendering",
            "local HTML or semantic hashes do not prove authenticated Studio, public reader, TUI, or real-client email behavior",
        ],
    }
    write("attack-roster.json", roster)
    write("surface-matrix.json", matrix)
    write("candidate-scorecards.json", {"schema_version": "legendary-e07-candidate-scorecards/v1", "assignment_id": "E07", "candidates": scorecards})
    write("threshold-outcomes.json", {"schema_version": "legendary-e07-threshold-outcomes/v1", "assignment_id": "E07", "frozen_thresholds_sha256": sha(E03 / "thresholds.json"), "outcomes": outcomes})
    write("rejection-evidence.json", rejections)
    write(".replay/timing.json", {"schema_version": "legendary-e07-volatile-timing/v1", "assignment_id": "E07", "wall_seconds": round(time.perf_counter() - started, 6), "fixtures": 36, "candidates": 3, "cells": len(cells), "tracked": False, "policy": "volatile replay measurement; tracked timing.json preserves the original E07 measured evidence"})
    print(f"E07 ATTACK BUILT candidates=3 fixtures=36 surfaces=5 cells={len(cells)} pass={matrix['status_counts']['pass']} fail={matrix['status_counts']['fail']} blocked={matrix['status_counts']['blocked']}")


if __name__ == "__main__":
    main()
