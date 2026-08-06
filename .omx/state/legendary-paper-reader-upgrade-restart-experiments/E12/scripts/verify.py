#!/usr/bin/env python3
"""Verify E12 authority, exact Converge token, coverage, blocks, replay, archive, and no-winner result."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def load(relative: str):
    return json.loads((HERE / relative).read_text())


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    args = parser.parse_args()
    checks: list[str] = []

    def require(name: str, condition: bool) -> None:
        if not condition:
            raise SystemExit(f"FAIL: {name}")
        checks.append(name)

    assignment = load("assignment.json")
    contract = load("contract/replacement-wave-contract.json")
    result = load("result.json")
    matrix = load("evidence/run-1/terminal-platform-matrix.json")
    rows = matrix["rows"]
    replay = load("reports/replay.json")
    require("authority", assignment["assignment_uuid"] == "39827795-e05e-4f99-944c-05fd1efdda43" and assignment["epic_task_id"] == "task-a768c69e659add58" and assignment["wave_revision"] == "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737")
    require("round", assignment["round"] == result["round"] == contract["round"] == "converge")
    require("exact result token", '"round":"converge"' in (HERE / "result.json").read_text())
    require("selection forbidden", assignment["candidate_selection_authorized"] is False and result["candidate_selected"] is False and contract["admission"]["candidate_selection_authorized"] is False)
    require("pilot forbidden", assignment["pilot_authorized"] is False and result["pilot_authorized"] is False and contract["admission"]["pilot_authorized"] is False)
    require("candidate coverage", {row["candidate"] for row in rows} == {"E04", "E05", "E06"})
    widths = [row for row in rows if row["gate"] == "hostile_width_full_rendering"]
    require("width coverage", len(widths) == 60 and {row["cell"].split(":")[-1] for row in widths} == {"1", "20", "40", "80", "120"})
    require("width replay", sum(row["status"] == "PASS" for row in widths) == 22 and sum(row["status"] == "FAIL" for row in widths) == 18 and sum(row["status"].startswith("BLOCKED") for row in widths) == 20)
    controls = [row for row in rows if row["gate"] == "control_sanitization"]
    require("control rejection", len(controls) == 3 and all(row["status"] == "FAIL" and row["evidence"]["observed_control_bytes"] for row in controls))
    require("E04 renderer block", any(row["candidate"] == "E04" and row["gate"] == "e04_renderer_coverage" and row["status"].startswith("BLOCKED") for row in rows))
    require("interaction blocks", len([row for row in rows if row["gate"] == "interaction_parity"]) == 27 and all(row["status"].startswith("BLOCKED") for row in rows if row["gate"] == "interaction_parity"))
    require("typed error blocks", len([row for row in rows if row["gate"] == "typed_errors"]) == 21 and all(row["status"].startswith("BLOCKED") for row in rows if row["gate"] == "typed_errors"))
    require("request ID accounted", len([row for row in rows if row["gate"] == "request_ids"]) == 3)
    require("identity accounted", len([row for row in rows if row["gate"] == "identity_domains"]) == 3 and sum(row["status"] == "PASS" for row in rows if row["gate"] == "identity_domains") == 1)
    require("ETag accounted", len([row for row in rows if row["gate"] == "etags"]) == 9 and sum(row["status"] == "PASS" for row in rows if row["gate"] == "etags") == 3)
    require("discovery accounted", len([row for row in rows if row["gate"] == "contract_discovery_agreement"]) == 15 and sum(row["status"] == "PASS" for row in rows if row["gate"] == "contract_discovery_agreement") == 1)
    require("contract fail closed", contract["admission"]["all_required_cells_must_pass"] is True and all(contract["admission"][key] is False for key in ("blocked_is_pass", "missing_is_pass", "proxy_is_pass", "static_only_is_pass")))
    executable = load("evidence/run-1/executable-contract-verdict.json")
    require("executable contract complete", executable["expected_cells_per_candidate"] == 48 and all(item["observed_cells"] == 48 and item["duplicate_count"] == 0 and not item["missing_cells"] and not item["unknown_cells"] for item in executable["candidate_evaluations"]))
    require("executable contract rejects", executable["no_winner"] is True and executable["eligible_candidates"] == [])
    require("no winner", load("evidence/run-1/no-winner.json")["no_winner"] is True and result["eligible_candidates"] == [])
    require("twice deterministic", replay["runs"] == 2 and replay["byte_identical"] is True)
    require("credential scan", load("reports/credential-scan.json")["hit_count"] == 0)
    require("archive", hashlib.sha256((HERE / "evidence.tar.gz").read_bytes()).hexdigest() == result["evidence_archive_sha256"])
    require("observations separate", result["preference"] == [] and len(result["observations"]) == 3)
    report = {"schema_version": "legendary-restart-e12-verification/v1", "status": "PASS_EVIDENCE_NO_WINNER", "round": "converge", "check_count": len(checks), "checks": checks, "result_verdict": result["verdict"]}
    rendered = canonical(report)
    if args.output:
        Path(args.output).write_text(rendered)
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
