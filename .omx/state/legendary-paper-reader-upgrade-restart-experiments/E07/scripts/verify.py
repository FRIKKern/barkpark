#!/usr/bin/env python3
"""Fail-closed verifier for E07 evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(condition: bool, name: str, checks: list[dict]) -> None:
    checks.append({"name": name, "status": "PASS" if condition else "FAIL"})


def main() -> int:
    assignment = json.loads((ROOT / "assignment.json").read_text())
    matrix = json.loads((ROOT / "generated" / "reports" / "candidate-matrix.json").read_text())
    replay = json.loads((ROOT / "reports" / "replay.json").read_text())
    credential = json.loads((ROOT / "reports" / "credential-scan.json").read_text())
    result = json.loads((ROOT / "result.json").read_text())
    checks: list[dict] = []
    check(assignment["assignment_uuid"] == "028be543-f502-427c-8940-5d0a6f386b2e", "assignment_uuid", checks)
    check(assignment["round"] == "attack" and matrix["round"] == "attack" and result["round"] == "attack", "round_exact", checks)
    check(result["epic_task_id"] == "task-a768c69e659add58" and result["wave_revision"] == "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737", "authority", checks)
    check(len(matrix["candidates"]) == 3 and len(matrix["cells"]) == 33, "typed_matrix_3x11", checks)
    required = {"conflicting_header_head", "genuinely_headerless_table", "nested_list", "malformed_list", "marks_tone_aliases", "missing_fields", "exact_empty_boundaries", "long_unbroken_token", "cas_conflict", "twice_idempotent_replay", "exact_rollback"}
    check(all({cell["probe"] for cell in matrix["cells"] if cell["candidate"] == c["candidate"]} == required for c in matrix["candidates"]), "attack_coverage", checks)
    check(all(not c["candidate_selected"] and not c["all_attacked_hard_gates_pass"] for c in matrix["candidates"]) and matrix["selected_candidate"] is None, "no_invalid_selection", checks)
    check(matrix["hard_thresholds"] == {k: 0 for k in matrix["hard_thresholds"]}, "zero_thresholds_unchanged", checks)
    check(matrix["real_reader_evidence"]["proxy_passes"] == 0, "no_proxy_reader_passes", checks)
    check(all(json.loads(path.read_text())["byte_exact"] for path in sorted((ROOT / "generated" / "receipts" / "rollback").glob("*.json"))), "exact_rollback_3_of_3", checks)
    check(len(list((ROOT / "generated" / "receipts" / "quarantine").glob("*.json"))) == 3, "quarantine_receipts_3", checks)
    check(replay["runs"] == 2 and replay["byte_identical"], "twice_reproducible", checks)
    check(credential["finding_count"] == 0, "credential_scan", checks)
    archive = ROOT / "evidence.tar.gz"
    check(archive.is_file() and hashlib.sha256(archive.read_bytes()).hexdigest() == result["evidence_archive_sha256"], "archive_digest", checks)
    failed = sum(item["status"] == "FAIL" for item in checks)
    report = {"schema_version": "legendary-paper-restart-e07-verification/v1", "status": "PASS" if failed == 0 else "FAIL", "passed": len(checks) - failed, "failed": failed, "checks": checks}
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
