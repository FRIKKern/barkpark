#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SEAL = Path(__file__).resolve().parent

def load(path):
    return json.loads(path.read_text())

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

contract = load(SEAL / "contract.json")
checks = []

def check(name, actual, expected):
    if actual != expected:
        raise AssertionError(f"{name}: {actual!r} != {expected!r}")
    checks.append(name)

check("schema", contract["schema_version"], "legendary-paper-round-01-seal/v1")
check("status", contract["status"], "SEALED_BASELINE_NOT_A_CANDIDATE")
check("inputs", len(contract["verification_inputs"]), 3)
check("gates", len(contract["frozen_gates"]), 15)
check("reconciliations", len(contract["reconciliations"]), 7)
check("candidates", [row["experiment"] for row in contract["round_2_candidates"]], ["E04", "E05", "E06"])
for row in contract["verification_inputs"]:
    path = ROOT / row["path"]
    check(f"exists:{row['experiment']}", path.is_file(), True)
    check(f"hash:{row['experiment']}", digest(path), row["sha256"])

e01 = load(ROOT / ".omx/state/legendary-paper-reader-upgrade-experiments/E01/reports/census.json")
e02 = load(ROOT / ".omx/state/legendary-paper-reader-upgrade-experiments/E02/result.json")
e03 = load(ROOT / ".omx/state/legendary-paper-reader-upgrade-experiments/E03/reports/verification.json")["payload"]
d = contract["canonical_denominators"]
for key, source in {
    "blocks": "block_count", "tables": "table_count", "authored_legacy_header_cells": "legacy_header_cells",
    "genuinely_headerless_tables": "headerless_tables", "body_cells": "body_cells", "callouts": "callout_count",
    "mark_records": "mark_records", "exact_empty_spacers": "exact_empty_spacers",
    "cch29_nested_list_items": "nested_paragraph_list_items", "cch29_nested_list_words": "nested_paragraph_list_words"
}.items():
    check(f"denominator:{key}", d[key], e01["totals"][source])
check("e02-inventory", e02["inventory_digest"], contract["inventory_digest"])
check("e02-public-text", next(x for x in e02["threshold_results"] if x["id"] == "public_visible_text")["passed"], 813)
check("e02-public-text-total", next(x for x in e02["threshold_results"] if x["id"] == "public_visible_text")["total"], 815)
check("e02-table-semantics", next(x for x in e02["threshold_results"] if x["id"] == "table_accessibility")["passed"], 0)
check("e03-render-cells", e03["surface_matrix"]["render_cells"], 32)
check("e03-terminal-width", e03["threshold_results"]["width"], "PASS")
check("e03-navigation", e03["threshold_results"]["navigation"], "FAIL")
check("blocked-gate", next(x for x in contract["frozen_gates"] if x["id"] == "real-reader-capabilities")["baseline"], "BLOCKED_NOT_PROXY_PASSED")

canonical = json.dumps(contract, sort_keys=True, separators=(",", ":")).encode()
print(json.dumps({
    "schema_version": "legendary-paper-round-01-seal-verification/v1",
    "status": "PASS",
    "checks": len(checks),
    "contract_sha256": hashlib.sha256(canonical).hexdigest()
}, sort_keys=True, separators=(",", ":")))
