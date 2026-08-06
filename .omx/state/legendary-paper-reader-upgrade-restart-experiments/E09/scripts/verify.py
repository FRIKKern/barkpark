#!/usr/bin/env python3
"""Fail closed on E09 authority, coverage, replay, block honesty, and archive evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def load(relative: str):
    return json.loads((HERE / relative).read_text())


checks = []


def require(name: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {name}")
    checks.append(name)


assignment = load("assignment.json")
result = load("result.json")
run1 = HERE / "evidence" / "run-1"
widths = load("evidence/run-1/terminal-widths.json")["rows"]
controls = load("evidence/run-1/control-bytes.json")["rows"]
interactions = load("evidence/run-1/interaction-parity.json")["rows"]
discovery = load("evidence/run-1/discovery-agreement.json")["rows"]
errors = load("evidence/run-1/safe-errors.json")["rows"]
validators = load("evidence/run-1/validators-identities.json")

require("authority", assignment["assignment_uuid"] == "65cda1a4-64a1-45bd-a27d-1256e460210a" and assignment["wave_revision"] == "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737")
require("round", result["round"] == "attack" and assignment["round"] == "attack")
require("exact result token", '"round":"attack"' in (HERE / "result.json").read_text())
require("candidate coverage", {row["candidate"] for row in widths} == {"E04", "E05", "E06"})
require("width matrix", len(widths) == 60 and {row["width"] for row in widths} == {1, 20, 40, 80, 120})
require("bounded full content accounted", sum(row["status"] == "PASS" for row in widths) == 22 and sum(row["status"] == "FAIL" for row in widths) == 18 and sum(row["status"].startswith("BLOCKED") for row in widths) == 20)
require("E05 width pass", all(row["status"] == "PASS" for row in widths if row["candidate"] == "E05"))
require("E06 width failures observed", sum(row["status"] == "FAIL" for row in widths if row["candidate"] == "E06") == 18 and all(row["visible_carriers"] == row["planned_carriers"] for row in widths if row["candidate"] == "E06"))
require("control failures", len(controls) == 3 and all(row["status"] == "FAIL" and row["observed_control_bytes"] for row in controls))
require("interaction typed blocks", len(interactions) == 27 and all(row["status"].startswith("BLOCKED") for row in interactions))
require("discovery accounted", len(discovery) == 15 and sum(row["status"] == "PASS" for row in discovery) == 1 and all(row["status"] == "PASS" or row["status"].startswith("BLOCKED") for row in discovery))
require("safe errors typed blocks", len(errors) == 21 and all(row["status"].startswith("BLOCKED") and row["typed_error"] == "BLOCKED" and row["exit_code"] is None for row in errors))
require("no unsafe failure induction", load("evidence/run-1/safe-errors.json")["unsafe_live_failure_induction"] == 0)
require("conditional coverage", len(validators["conditional_rows"]) == 9 and sum(row["status"] == "PASS" for row in validators["conditional_rows"]) == 3)
require("identity coverage", len(validators["identity_rows"]) == 3 and sum(row["status"] == "FAIL" for row in validators["identity_rows"]) == 2)
require("twice deterministic", load("reports/replay.json")["runs"] == 2 and load("reports/replay.json")["byte_identical"] is True)
require("credential scan", load("reports/credential-scan.json")["hit_count"] == 0)
require("archive", (HERE / "evidence.tar.gz").is_file() and hashlib.sha256((HERE / "evidence.tar.gz").read_bytes()).hexdigest() == result["evidence_archive_sha256"])
require("no selection", result["candidate_selected"] is False and result["preference"] == [])

verification = {"schema_version": "legendary-restart-e09-verification/v1", "status": "PASS_EVIDENCE_ATTACK_FAILED", "round": "attack", "check_count": len(checks), "checks": checks, "result_verdict": result["verdict"]}
(HERE / "reports" / "verification.json").write_text(json.dumps(verification, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
print(json.dumps(verification, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
