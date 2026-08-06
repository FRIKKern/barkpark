#!/usr/bin/env python3
"""Fail-closed verifier for E10."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parent


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path) -> object:
    return json.loads(path.read_text())


def main() -> int:
    result = load(HERE / "result.json")
    assignment = load(HERE / "assignment.json")
    ledger = load(HERE / "reports" / "no-winner-ledger.json")
    repair = load(HERE / "repair-manifest.json")
    probe = load(HERE / "reports" / "repair-probe.json")
    replay = load(HERE / "reports" / "e07-independent-replay.json")
    sources = load(HERE / "reports" / "source-hashes.json")
    checks = []

    def check(name: str, condition: bool) -> None:
        if not condition:
            raise SystemExit("FAIL:" + name)
        checks.append(name)

    check("assignment_uuid", assignment["assignment_uuid"] == "a91f9813-3b34-4f62-96ff-8d817d5544f6")
    check("round_exact", result["round"] == ledger["round"] == repair["round"] == "converge")
    check("authority", all(result[key] == assignment[key] for key in ("epic_task_id", "wave_id", "wave_revision", "inventory_digest", "plan_digest")))
    check("no_selection", result["candidate_selected"] is False and result["selected_candidate"] is None and ledger["winner"] is None)
    check("pilot_unauthorized", result["pilot_authorized"] is False and ledger["pilot_authorized"] is False and repair["pilot_authorized"] is False)
    check("typed_no_winner", result["typed_verdict"] == "CONVERGE_COMPLETE_NO_WINNER_REPLACEMENT_WAVE_REQUIRED")
    check("three_candidates", [row["candidate"] for row in ledger["candidates"]] == ["E04", "E05", "E06"])
    check("no_candidate_clears", all(row["clears_every_hard_gate"] is False for row in ledger["candidates"]))
    check("e07_failure_count", result["e07_hard_failures_reproduced"] == 10)
    check("e07_rejection_counts", {key: len(value) for key, value in ledger["e07_preservation_schema_rejections"].items()} == {"E04": 3, "E05": 3, "E06": 4})
    check("e07_replay_twice", replay["runs"] == 2 and replay["byte_identical"] is True and replay["run_1_sha256"] == replay["run_2_sha256"])
    check("e08_counts", ledger["e08_totals"] == {"BLOCKED": 52, "FAIL": 24, "PASS": 32})
    check("e08_rejects_all", all(row["e08_verdict"] == "REJECT" for row in ledger["candidates"]))
    check("e09_counts", ledger["e09_scores"] == {"control_byte_failures": 3, "status_counts": {"BLOCKED": 88, "FAIL": 23, "PASS": 30}, "width_cells_blocked": 20, "width_cells_fail": 18, "width_cells_pass": 22, "width_cells_total": 60})
    check("e09_failures_complete", ledger["e09_hard_failures"] == ["terminal_control_leaks:E04", "terminal_control_leaks:E05", "terminal_control_leaks:E06", "bounded_rendering:E06:18_of_20_cells", "missing_request_id:E04", "missing_request_id:E06", "identity_domains_incomplete:E04"])
    check("thresholds_zero", len(repair["hard_thresholds"]) == 14 and all(value == 0 for value in repair["hard_thresholds"].values()))
    expected_mechanisms = ["alias_conflicts", "malformed_structures", "long_token_geometry", "write_cas", "rollback_quarantine", "terminal_sanitization", "reader_adapters"]
    check("repair_mechanisms", [row["id"] for row in repair["mechanisms"]] == expected_mechanisms)
    check("probe_alias", probe["alias_conflict"]["status"] == "QUARANTINE" and probe["equal_alias"]["status"] == "ACCEPT")
    check("probe_malformed", probe["malformed_structure"]["status"] == "QUARANTINE")
    check("probe_geometry", all(value <= int(width) for width, value in probe["long_token_max_widths"].items()))
    check("probe_cas", probe["write_cas"]["conflict"] == {"payload_written": False, "retry": False, "status": "CONFLICT"})
    check("probe_rollback", probe["rollback_quarantine"]["byte_exact"] is True and probe["rollback_quarantine"]["preimage_sha256"] == probe["rollback_quarantine"]["restored_sha256"])
    check("probe_terminal", probe["terminal_sanitization"]["input_control_count"] == 3 and probe["terminal_sanitization"]["output_control_count"] == 0)
    check("probe_adapters", probe["reader_adapters"] == ["public", "Studio", "TUI", "email", "CLI/API"])
    check("source_hashes", all(sha256(ROOT / row["path"]) == row["sha256"] for row in sources["sources"]))
    check("archive", sha256(HERE / result["evidence"]) == result["evidence_archive_sha256"])
    check("observations_preferences_separate", len(result["observations"]) == 3 and result["preferences"] == [])
    output = {
        "schema_version": "legendary-paper-restart-e10-verification/v1",
        "status": "PASS",
        "round": "converge",
        "check_count": len(checks),
        "checks": checks,
        "typed_verdict": result["typed_verdict"],
        "result_sha256": sha256(HERE / "result.json"),
    }
    print(canonical(output).decode(), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
