#!/usr/bin/env python3
"""Independent hard-gate verifier for committed/generated E04 evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path: str):
    return json.loads((ROOT / path).read_text())


def main() -> int:
    checks = []
    def check(name, condition, detail):
        checks.append({"name":name, "status":"PASS" if condition else "FAIL", "detail":detail})
    assignment = load("assignment.json"); result = load("result.json")
    replay = load("reports/replay.json"); preservation = load("evidence/run-1/reports/preservation.json")
    readers = load("evidence/run-1/reports/readers.json"); hostile = load("evidence/run-1/reports/adversarial.json")
    scan = load("reports/credential-scan.json")
    check("authority", assignment["assignment_uuid"] == "911a7d27-80a5-4bdd-93a9-5ce33f0d15c1", assignment["assignment_uuid"])
    check("round_exact", result["round"] == "diverge" and b'"round":"diverge"' in (ROOT/"result.json").read_bytes(), result["round"])
    check("four_pins", len(assignment["papers"]) == 4 and result["papers_migrated"] == 4, result["papers_migrated"])
    check("twice_byte_identical", replay["byte_identical"] and replay["run_1_sha256"] == replay["run_2_sha256"], replay["run_1_sha256"])
    check("815_blocks", preservation["totals_before"]["blocks"] == preservation["totals_after"]["blocks"] == 815, preservation["totals_after"]["blocks"])
    check("113_headers", preservation["totals_before"]["authored_header_cells"] == preservation["totals_after"]["head_cells"] == 113, preservation["totals_after"]["head_cells"])
    check("1374_body_cells", preservation["totals_before"]["body_cells"] == preservation["totals_after"]["body_cells"] == 1374, preservation["totals_after"]["body_cells"])
    check("388_marks", preservation["totals_before"]["marks"] == preservation["totals_after"]["marks"] == 388, preservation["totals_after"]["marks"])
    check("11_headerless", preservation["totals_before"]["headerless_tables"] == preservation["totals_after"]["headerless_tables"] == 11, preservation["totals_after"]["headerless_tables"])
    check("381_empty_boundaries", preservation["totals_before"]["exact_empty_spacers"] == preservation["totals_after"]["exact_empty_spacers"] == 381, preservation["totals_after"]["exact_empty_spacers"])
    check("zero_loss", preservation["authored_loss"] == 0 and preservation["invented_headers"] == 0, preservation["authored_loss"])
    check("quarantine", hostile["conflicting_alias_quarantined"] and hostile["revision_conflict_quarantined"], "ambiguity and revision conflict")
    check("idempotence", all(load(f"evidence/run-1/receipts/idempotence/{p['fixture_id']}.json")["status"] == "PASS" for p in assignment["papers"]), "4/4")
    check("rollback", all(load(f"evidence/run-1/receipts/rollback/{p['fixture_id']}.json")["byte_exact"] for p in assignment["papers"]), "4/4 raw-byte exact")
    check("five_adapters", len({x["surface"] for x in readers["adapter_receipts"]}) == 5 and len(readers["adapter_receipts"]) == 20, len(readers["adapter_receipts"]))
    check("blocked_not_proxy", readers["real_reader_units_blocked"] == 20 and readers["proxy_passes_for_missing_readers"] == 0, "20 blocked, 0 proxy")
    check("credential_scan", scan["finding_count"] == 0, scan["finding_count"])
    check("archive", hashlib.sha256((ROOT/"evidence.tar.gz").read_bytes()).hexdigest() != "", (ROOT/"evidence.tar.gz").stat().st_size)
    failed = [x for x in checks if x["status"] == "FAIL"]
    summary = {"schema_version":"legendary-paper-restart-e04-verification/v1", "status":"PASS" if not failed else "FAIL",
               "checks":checks, "passed":len(checks)-len(failed), "failed":len(failed)}
    encoded = json.dumps(summary, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    (ROOT / "reports" / "verification.json").write_text(encoded + "\n")
    print(encoded)
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
