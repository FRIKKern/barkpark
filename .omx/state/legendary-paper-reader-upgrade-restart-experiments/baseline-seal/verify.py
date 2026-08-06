#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


contract = json.loads((HERE / "contract.json").read_text())
checks = []


def check(name: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {name}")
    checks.append(name)


check("schema", contract["schema_version"] == "legendary-paper-restart-baseline-seal/v1")
check("round", contract["round"] == "baseline" and contract["round_count"] == 3)
check("no_candidate", contract["candidate_selected"] is False)
check("assignment_ids", [row["id"] for row in contract["assignments"]] == [
    "restart-experiment-01", "restart-experiment-02", "restart-experiment-03"
])
for row in contract["assignments"]:
    check(f"result:{row['id']}", sha256(ROOT / row["result_path"]) == row["result_sha256"])
    check(f"archive:{row['id']}", sha256(ROOT / row["archive_path"]) == row["archive_sha256"])

expected_denominators = {
    "papers": 4,
    "reader_units": 20,
    "blocks": 815,
    "authored_header_cells": 113,
    "table_body_cells": 1374,
    "marks": 388,
    "callouts": 30,
    "headerless_tables": 11,
    "exact_empty_spacers": 381,
    "cch29_nested_list_items": 11,
    "cch29_nested_list_words": 406,
}
check("denominators", contract["denominators"] == expected_denominators)
check("zero_thresholds", all(value == 0 for value in contract["hard_thresholds"].values()))
check("taxonomy", len(contract["failure_taxonomy"]) == 11)
check("candidate_ids", [row["id"] for row in contract["diverge_candidates"]] == [
    "restart-experiment-04", "restart-experiment-05", "restart-experiment-06"
])
check("blocked_not_passed", all(
    value.startswith("blocked_")
    for value in (
        contract["baseline_observations"]["human_readers"]["authenticated_studio"],
        contract["baseline_observations"]["human_readers"]["real_assistive_technology"],
        contract["baseline_observations"]["human_readers"]["delivered_mail_clients"],
    )
))

print(json.dumps({
    "status": "PASS",
    "round": "baseline",
    "check_count": len(checks),
    "contract_sha256": sha256(HERE / "contract.json"),
}, sort_keys=True, separators=(",", ":")))
