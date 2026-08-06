#!/usr/bin/env python3
import hashlib
import json
import sys
import tarfile
from pathlib import Path

E11 = Path(__file__).resolve().parents[1]
ROOT = E11.parent
load = lambda p: json.loads((E11 / p).read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
checks = []


def check(name, condition):
    if not condition:
        raise SystemExit(f"FAIL: {name}")
    checks.append(name)


assignment = load("assignment.json")
result = load("result.json")
matrix = load("reports/human-reader-matrix.json")
observed = load("reports/observed-failures.json")
blocked = load("reports/blocked-cells.json")
fixtures = load("reports/fixture-validation.json")
repro = load("reports/reproducibility.json")
scan = load("reports/credential-scan.json")
no_winner = load("reports/no-winner.json")
inputs = load("reports/input-hashes.json")

check("assignment", assignment["assignment_id"] == "restart-experiment-11" and assignment["assignment_uuid"] == "1f343fdc-85c3-4aeb-a5e8-0fb2a13eaef8")
check("authority", assignment["epic_task_id"] == "task-a768c69e659add58" and assignment["wave_revision"] == "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737")
check("exact_round", result["round"] == "converge" and '"round":"converge"' in (E11 / "result.json").read_text())
check("no_selection", result["candidate_selected"] is False and no_winner["candidate_selected"] is False)
check("pilot_closed", result["pilot_authorized"] is False and no_winner["pilot_authorized"] is False)
check("three_rejected", len(result["candidate_outcomes"]) == 3 and all(r["verdict"] == "REJECT" and not r["winner_eligible"] for r in result["candidate_outcomes"]))
check("observed_failures", observed["count"] > 0 and all(r["status"] == "FAIL" for r in observed["rows"]))
check("blocked_separate", blocked["count"] > 0 and all(r["status"] == "BLOCKED" for r in blocked["rows"]))
check("counts_reconcile", observed["count"] == matrix["counts"]["FAIL"] and blocked["count"] == matrix["counts"]["BLOCKED"])
check("every_candidate_failed_and_blocked", all(r["observed_failures"] > 0 and r["blocked_cells"] > 0 for r in result["candidate_outcomes"]))
check("header_intent", any(r["candidate"] == "E06" and r["fixture"] == "PDS45" and r["axis"] == "table_header_intent" and r["status"] == "PASS" and r["observed"]["headerless_tables"] == 9 for r in matrix["rows"]))
check("e05_mime_observed_fail", all(r["status"] == "FAIL" and not r["observed"]["headers"]["From"] and not r["observed"]["headers"]["To"] and not r["observed"]["headers"]["Message-ID"] for r in matrix["rows"] if r["candidate"] == "E05" and r["axis"] == "mime_plus_from_to_message_id"))
check("studio_blocked", all(any(r["candidate"] == c and r["surface"] == "studio" and r["status"] == "BLOCKED" for r in matrix["rows"]) for c in ("E04", "E05", "E06")))
check("real_at_blocked", all(any(r["candidate"] == c and r["surface"] == "assistive_technology" and r["status"] == "BLOCKED" for r in matrix["rows"]) for c in ("E04", "E05", "E06")))
check("delivered_mail_blocked", all(any(r["candidate"] == c and r["surface"] == "delivered_mail" and r["status"] == "BLOCKED" for r in matrix["rows"]) for c in ("E04", "E05", "E06")))
check("cache_blocked", all(any(r["candidate"] == c and r["surface"] == "cache" and r["status"] == "BLOCKED" for r in matrix["rows"]) for c in ("E04", "E05", "E06")))
check("frame_mismatch_observed", any(r["axis"] == "focus_order_overflow_exact_frame" and r["viewport"] in ("390", "320") and r["status"] == "FAIL" and r["observed"]["clientWidth"] == 500 for r in matrix["rows"]))
check("fixtures", fixtures["status"] == "PASS" and all(fixtures["checks"].values()))
check("reproducible", repro["status"] == "PASS" and repro["run_1"] == repro["run_2"])
check("credential_scan", scan["status"] == "PASS" and not scan["hits"])
for rel, digest in inputs.items():
    check(f"input:{rel}", sha(ROOT / rel) == digest)
check("archive_hash", result["artifact_set_sha256"] == sha(E11 / "evidence.tar.gz"))
with tarfile.open(E11 / "evidence.tar.gz", "r:gz") as archive:
    names = set(archive.getnames())
check("archive_members", {"result.json", "reports/human-reader-matrix.json", "reports/no-winner.json", "fixtures/replacement-wave-requirements.json", "handoff.json"}.issubset(names))

receipt = {"schema_version": "legendary-paper-reader-e11-verification/v1", "status": "PASS", "round": "converge", "check_count": len(checks), "checks": checks, "matrix_sha256": sha(E11 / "reports/human-reader-matrix.json"), "result_sha256": sha(E11 / "result.json"), "archive_sha256": sha(E11 / "evidence.tar.gz")}
run = int(sys.argv[1]) if len(sys.argv) > 1 else 1
if run not in (1, 2):
    raise SystemExit("verification run must be 1 or 2")
(E11 / f"reports/verification-run-{run}.json").write_text(json.dumps(receipt, sort_keys=True, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
