#!/usr/bin/env python3
"""Read-only, idempotent verifier for the E01 baseline artifact set."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load(rel: str) -> Any:
    return json.loads((ROOT / rel).read_text())


def fail(message: str) -> None:
    raise AssertionError(message)


def main() -> int:
    assignment = load("assignment.json")
    census = load("reports/census.json")
    probes = load("reports/reader-probes.json")
    thresholds = load("reports/thresholds.json")
    taxonomy = load("reports/failure-taxonomy.json")
    controls = load("fixtures/controls.json")
    bad = load("fixtures/known-bad.json")
    adversarial = load("fixtures/adversarial.json")
    manifest = load("reports/hash-manifest.json")

    checks: list[dict[str, Any]] = []

    def check(name: str, actual: Any, expected: Any) -> None:
        if actual != expected:
            fail(f"{name}: {actual!r} != {expected!r}")
        checks.append({"name": name, "actual": actual, "expected": expected, "pass": True})

    check("assignment_id", assignment["assignment_id"], "experiment-01")
    check("round", assignment["round"], 1)
    check("inventory_digest", assignment["inventory_digest"], "3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e")
    check("candidate_count", len(assignment["candidate_ids"]), 0)
    check("paper_count", len(census["papers"]), 4)
    check("revision_matches", sum(p["revision"] == a["revision"] for p, a in zip(census["papers"], assignment["papers"])), 4)
    check("canonical_blocks", census["totals"]["block_count"], 815)
    check("legacy_header_cells", census["totals"]["legacy_header_cells"], 113)
    check("modern_head_cells", census["totals"]["modern_head_cells"], 0)
    check("headerless_tables", census["totals"]["headerless_tables"], 11)
    check("body_cells", census["totals"]["body_cells"], 1374)
    check("mark_records", census["totals"]["mark_records"], 388)
    check("exact_empty_spacers", census["totals"]["exact_empty_spacers"], 381)
    check("cch29_nested_items", census["papers"][0]["nested_paragraph_list_items"], 11)
    check("cch29_nested_words", census["papers"][0]["nested_paragraph_list_words"], 406)
    check("cch29_nested_characters", census["papers"][0]["nested_paragraph_list_characters"], 2268)
    check("unique_ids_per_paper", [p["unique_block_ids"] for p in census["papers"]], [252, 227, 237, 99])

    check("reader_probe_papers", len(probes["papers"]), 4)
    check("api_source_passes", sum(p["cli_api"]["status"] == "pass" and p["source"]["status"] == "pass" for p in probes["papers"]), 4)
    check("captured_public", sum(p["public"]["status"] == "captured" for p in probes["papers"]), 4)
    check("captured_email", sum(p["email"]["status"] == "captured" for p in probes["papers"]), 4)
    check("captured_tui80", sum(p["tui80"]["status"] == "captured" for p in probes["papers"]), 4)
    check("email_header_cells", sum(p["email"]["legacy_header_th_instances"] for p in probes["papers"]), 113)
    check("email_presentation_tables", sum(p["email"]["presentation_table_instances"] for p in probes["papers"]), 46)
    check("cch29_email_nested_words_survived", probes["papers"][0]["email"]["nested_list_survival"]["words_survived"], 0)
    check("cch29_tui_nested_words_survived", probes["papers"][0]["tui80"]["nested_list_survival"]["words_survived"], 0)

    check("threshold_count", len(thresholds["hard_thresholds"]), 10)
    check("taxonomy_observed_count", len(taxonomy["observed"]), 7)
    check("control_dimensions", len(controls["dimensions"]), 10)
    check("known_bad_targets", len(bad["targets"]), 5)
    check("adversarial_fixture_count", len(adversarial["fixtures"]), 15)
    check("conflicting_header_head_fixture", sum(f["id"] == "header-head-conflict" for f in adversarial["fixtures"]), 1)
    check("adversarial_dimensions", sorted({f["dimension"] for f in adversarial["fixtures"]}), ["empty_spacer", "header_head", "list", "mark", "tone"])

    observed_files = []
    for row in manifest["files"]:
        path = ROOT / row["path"]
        if not path.is_file():
            fail(f"missing artifact: {row['path']}")
        data = path.read_bytes()
        check(f"hash:{row['path']}", sha256(data), row["sha256"])
        check(f"bytes:{row['path']}", len(data), row["bytes"])
        observed_files.append(row)
    check("artifact_set_sha256", sha256(canonical_bytes(observed_files)), manifest["artifact_set_sha256"])

    result = {
        "schema_version": "legendary-paper-e01-verification/v1",
        "status": "PASS",
        "artifact_set_sha256": manifest["artifact_set_sha256"],
        "check_count": len(checks),
        "hard_metrics": {
            "canonical_blocks": 815,
            "legacy_header_cells": 113,
            "body_cells": 1374,
            "mark_records": 388,
            "exact_empty_spacers": 381,
            "cch29_nested_list_words": 406,
        },
    }
    sys.stdout.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"E01 VERIFY FAIL: {exc}\n")
        raise SystemExit(1)
