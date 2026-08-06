#!/usr/bin/env python3
"""Evaluate any replacement-wave matrix against the frozen E12 required-cell contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    contract = json.loads((HERE / "contract" / "replacement-wave-contract.json").read_text())
    matrix = json.loads(Path(args.matrix).read_text())
    requirements = contract["candidate_requirements"]
    candidates = sorted({row["candidate"] for row in matrix["rows"]})
    expected = {
        ("control_sanitization", "controls:hostile"),
        ("e04_renderer_coverage", "renderer:all-width"),
        ("request_ids", "request_id:success-and-errors"),
        ("identity_domains", "identity:six-domains"),
    }
    expected.update(("hostile_width_full_rendering", f"width:{fixture}:{width}") for fixture in requirements["fixtures"] for width in requirements["widths"])
    expected.update(("interaction_parity", f"interaction:{operation}") for operation in requirements["interaction_operations"])
    expected.update(("typed_errors", f"error:{case}") for case in requirements["error_cases"])
    expected.update(("etags", f"etag:{case}") for case in requirements["validator_cases"])
    expected.update(("contract_discovery_agreement", f"discovery:{surface}") for surface in requirements["discovery_surfaces"])
    evaluations = []
    eligible = []
    for candidate in candidates:
        candidate_rows = [row for row in matrix["rows"] if row["candidate"] == candidate]
        keyed = {(row["gate"], row["cell"]): row for row in candidate_rows}
        duplicate_count = len(candidate_rows) - len(keyed)
        missing = sorted(f"{gate}:{cell}" for gate, cell in expected - set(keyed))
        unknown = sorted(f"{gate}:{cell}" for gate, cell in set(keyed) - expected)
        non_pass = sorted([{"gate": gate, "cell": cell, "status": keyed[(gate, cell)]["status"]} for gate, cell in expected & set(keyed)], key=lambda item: (item["gate"], item["cell"]))
        non_pass = [item for item in non_pass if item["status"] != "PASS"]
        admitted = duplicate_count == 0 and not missing and not unknown and not non_pass
        if admitted:
            eligible.append(candidate)
        evaluations.append({"candidate": candidate, "expected_cells": len(expected), "observed_cells": len(candidate_rows), "duplicate_count": duplicate_count, "missing_cells": missing, "unknown_cells": unknown, "non_pass_cells": non_pass, "eligible": admitted})
    verdict = {"schema_version": "legendary-restart-e12-executable-contract-verdict/v1", "round": "converge", "contract_sha256_basis": "canonical checked-in contract bytes", "expected_cells_per_candidate": len(expected), "candidate_evaluations": evaluations, "eligible_candidates": eligible, "no_winner": not eligible, "candidate_selected": False, "pilot_authorized": False}
    rendered = canonical(verdict)
    if args.output:
        Path(args.output).write_text(rendered)
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
