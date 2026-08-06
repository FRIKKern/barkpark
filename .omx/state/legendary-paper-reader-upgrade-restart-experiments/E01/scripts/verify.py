#!/usr/bin/env python3
"""Read-only replay verifier for restart Experiment E01."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from canonicalizer import canonical_bytes, sha256


ROOT = Path(__file__).resolve().parents[1]


def load(rel: str) -> Any:
    return json.loads((ROOT / rel).read_text())


def main() -> int:
    assignment = load("assignment.json")
    census = load("reports/census.json")
    loss = load("reports/block-loss-manifest.json")
    taxonomy = load("reports/failure-taxonomy.json")
    controls = load("fixtures/controls.json")
    known_bad = load("fixtures/known-bad.json")
    adversarial = load("fixtures/adversarial.json")
    adversarial_probes = load("reports/adversarial-probes.json")
    commands = load("reports/commands.json")
    attribution = load("reports/cycle-attribution.json")
    mutation = load("reports/zero-external-mutation-proof.json")
    token_scan = load("reports/saved-token-scan.json")
    manifest = load("reports/hash-manifest.json")
    checks: list[dict[str, Any]] = []

    def check(name: str, actual: Any, expected: Any) -> None:
        if actual != expected:
            raise AssertionError(f"{name}: {actual!r} != {expected!r}")
        checks.append({"name": name, "pass": True})

    check("assignment_id", assignment["assignment_id"], "restart-experiment-01")
    check("assignment_uuid", assignment["assignment_uuid"], "f5556476-4677-4f31-ab90-d7bf5b9134ee")
    check("round", assignment["round"], "baseline")
    check("epic", assignment["epic_task_id"], "task-a768c69e659add58")
    check("wave", assignment["wave_id"], "legendary-paper-reader-upgrade-wave-2026-08-06-restart")
    check("inventory_digest", assignment["inventory_digest"], "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc")
    check("live_assignment_uuid", attribution["assignment_attribution"]["cycle_assignment_id"], assignment["assignment_uuid"])
    check("live_assignment_snapshot_digest", attribution["assignment_attribution"]["snapshot_digest"], "ff80dabc04570e7adc99416251d9bd19dfb90d5a2d7c1d30ceedca7a422b8118")
    check("live_wave_revision", attribution["authority"]["wave_revision"], assignment["wave_revision"])
    check("paper_count", len(census["papers"]), 4)
    check("pins", [row["revision"] for row in census["papers"]], [paper["revision"] for paper in assignment["papers"]])
    check("per_paper_blocks", [row["blocks"] for row in census["papers"]], [237, 252, 99, 227])
    check("blocks", census["totals"]["blocks"], 815)
    check("authored_headers", census["totals"]["authored_header_cells"], 113)
    check("modern_heads", census["totals"]["modern_head_cells"], 0)
    check("headerless_tables", census["totals"]["headerless_tables"], 11)
    check("body_cells", census["totals"]["table_body_cells"], 1374)
    check("marks", census["totals"]["marks"], 388)
    cch29 = next(row for row in census["papers"] if row["fixture_id"] == "CCH29")
    check("cch29_nested_items", cch29["nested_paragraph_items"], 11)
    check("cch29_nested_words", cch29["nested_paragraph_words"], 406)
    check("cch29_nested_characters", cch29["nested_paragraph_characters"], 2268)
    check("loss_manifest_blocks", loss["summary"]["blocks"], 815)
    check("exact_blocks", loss["summary"]["exact"], 815)
    check("authored_loss_events", loss["summary"]["authored_loss_events"], 0)
    check("invented_headers", loss["summary"]["invented_header_cells"], 0)
    check("taxonomy_observations", len(taxonomy["observations"]), 4)
    check("taxonomy_canonicalizer_failures", len(taxonomy["canonicalizer_failures"]), 0)
    check("controls", len(controls["controls"]), 4)
    check("known_bad_blocks", len(known_bad["fixtures"]), 2)
    check("adversarial", len(adversarial["fixtures"]), 10)
    check("adversarial_probe_total", adversarial_probes["summary"]["total"], 10)
    check("adversarial_probe_exact", adversarial_probes["summary"]["exact"], 10)
    check("adversarial_invented_headers", adversarial_probes["summary"]["invented_header_cells"], 0)
    check("read_only_commands", {row["class"] for row in commands["commands"]}, {"read_only"})
    check("write_commands", commands["write_commands"], 0)
    check("git_unchanged", mutation["git_unchanged"], True)
    check("production_mutations", mutation["production_mutations"], 0)
    check("task_paper_cycle_mutations", mutation["task_paper_cycle_mutations"], 0)
    check("saved_token_hits", token_scan["hit_count"], 0)
    check("secrets_persisted", token_scan["secret_values_persisted"], False)
    observed_files = []
    for row in manifest["files"]:
        path = ROOT / row["path"]
        if not path.is_file():
            raise AssertionError(f"missing artifact: {row['path']}")
        data = path.read_bytes()
        check(f"hash:{row['path']}", sha256(data), row["sha256"])
        check(f"bytes:{row['path']}", len(data), row["bytes"])
        observed_files.append(row)
    check("artifact_set_sha256", sha256(canonical_bytes(observed_files)), manifest["artifact_set_sha256"])
    result = {
        "artifact_set_sha256": manifest["artifact_set_sha256"],
        "assignment_id": assignment["assignment_id"],
        "assignment_uuid": assignment["assignment_uuid"],
        "check_count": len(checks),
        "hard_gates": {"authored_loss": 0, "blocks": 815, "headers": 113, "invented_headers": 0, "marks": 388, "table_body_cells": 1374},
        "round": "baseline",
        "status": "PASS",
        "verdict": "BASELINE_CANONICALIZER_PASS",
    }
    sys.stdout.buffer.write(canonical_bytes(result) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"restart E01 verify failed: {exc}\n")
        raise SystemExit(1)
