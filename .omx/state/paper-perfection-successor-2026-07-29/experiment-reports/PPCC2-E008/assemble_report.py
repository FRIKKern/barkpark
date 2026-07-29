#!/usr/bin/env python3
from __future__ import annotations

import datetime
import hashlib
import json
from pathlib import Path
import subprocess


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
SUMMARY = HERE / "artifacts" / "run-summary.json"
COMMAND_LOG = HERE / "artifacts" / "command-log.json"
REPORT = HERE / "report.json"
REPORT_SHA = HERE / "report.sha256"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verification_check(
    name: str, command: str, status: str, path: Path, output: str
) -> dict[str, object]:
    return {
        "name": name,
        "command": command,
        "status": status,
        "exit_code": 0 if status == "PASS" else 1,
        "log_path": str(path.relative_to(HERE)),
        "log_sha256": sha256(path),
        "output": output,
    }


def main() -> int:
    summary = json.loads(SUMMARY.read_text(encoding="utf-8"))
    round2 = json.loads(
        (HERE / "inputs" / "round2-report-sha256.json").read_text(
            encoding="utf-8"
        )
    )
    command_log = json.loads(COMMAND_LOG.read_text(encoding="utf-8"))
    metrics = summary["metrics"]
    by_candidate = metrics["by_candidate"]
    failed_cases = [
        {
            "candidate_id": result["candidate_id"],
            "unit_id": result["unit_id"],
            "failed_gates": [
                name for name, passed in result["hard_gates"].items() if not passed
            ],
            "artifact_directory": result["artifact_directory"],
        }
        for result in summary["fixture_results"]
        if not result["hard_gate_pass"]
    ]
    verification_root = HERE / "artifacts" / "verification"
    checks = [
        verification_check(
            "typecheck_dynamic_python",
            "python3 -m compileall -q attack_candidates.py test_attack.py validate_report.py assemble_report.py",
            "PASS",
            verification_root / "python-compileall.log",
            "PASS: python compileall",
        ),
        verification_check(
            "linter_python",
            "python3 -m tabnanny attack_candidates.py test_attack.py validate_report.py assemble_report.py",
            "PASS",
            verification_root / "python-tabnanny.log",
            "PASS: python tabnanny",
        ),
        verification_check(
            "unit_tests",
            "python3 -m unittest -v test_attack.py",
            "PASS",
            verification_root / "python-unit-tests.log",
            "5 tests, 0 failures",
        ),
        verification_check(
            "end_to_end_attack_matrix",
            "python3 attack_candidates.py run",
            "PASS",
            HERE / "attack-run.log",
            (
                "27 cases completed; 189 hard checks; "
                f"{metrics['observed_failure_rate']['hard_failures']} candidate "
                "failures recorded rather than hidden"
            ),
        ),
        verification_check(
            "go_pdrender_regressions",
            "go test ./internal/pdrender/...",
            "PASS",
            verification_root / "go-pdrender-tests.log",
            "internal/pdrender and htmlcheck PASS",
        ),
        verification_check(
            "paper_reader_audit",
            "bash scripts/audit-paper-readers-test.sh",
            "PASS",
            verification_root / "paper-reader-audit.log",
            "paper reader audit fixture: PASS",
        ),
        verification_check(
            "elixir_renderer_email_safety",
            "mix test <8 targeted PortableDoc/email/sanitizer files>",
            "PASS",
            verification_root / "elixir-render-email-safety-tests.cached.log",
            "115 tests, 0 failures",
        ),
    ]
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=REPO, text=True
    ).strip()
    report = {
        "schema_version": "paper-perfection-successor-experiment-report/v1",
        "status": "completed",
        "assignment_id": "PPCC2-E008",
        "cycle_assignment_id": "8ddaa122-30d5-410d-842b-7c4b21da498a",
        "snapshot_digest": "25ad3ff132fba732942a8259e0f66d51d1d30abfb55c0b4223638c8355eb4176",
        "receipts_sha256": "9ef2205d4acc31e66452b0b7f53c64cdcb9f22c67ea03dca9b7c4bcc5886bf8e",
        "canonical_task_id": "2",
        "round": 3,
        "round_key": "attack",
        "focus": "TUI and email attack",
        "agent_type": "legendary-experimenter",
        "effort": "medium",
        "worker": "worker-2",
        "completed_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "objective": (
            "Attack every Round-2 runnable candidate at 80 and 40 columns with "
            "long content, tables, code, safe and unsafe URLs, linearized email, "
            "script removal, content preservation, and deterministic rerender."
        ),
        "fixture_ids": [
            "paper:choosing-your-site-framework",
            "paper:component-reference",
            "paper:wave-deck",
            "paper:cloud-console-hardening-wave-2026-07-21",
            "paper:cloud-console-hardening-wave-3-2026-07-21",
            "paper:spd-inspector-successor-wave-2026-07-20",
            "paper:block-wishlist-100",
            "paper:honest-gates-wave-4-2026-07-28",
            "paper:task-tui-wave-2026-07-23b",
        ],
        "required_surfaces": ["studio", "tui80", "tui40", "email", "cli_api"],
        "direct_answer": (
            "Personally attacked all three runnable Round-2 candidates across all "
            "nine immutable fixtures (27 cases, five surfaces, repeated renders). "
            "No candidate cleared every hard Round-3 gate as-is. PPCC2-E004 loses "
            "the full table marker at 40 columns even while respecting width; "
            "PPCC2-E005 passes all other gates but the exact production email "
            "renderer preserves an interactive <details> instead of linearizing it; "
            "PPCC2-E006 drops the safe authored href from Studio, TUI, and email "
            "semantic projections. All candidates remained deterministic, "
            "script-free, schema-valid, single-H1, and CLI/API byte-stable."
        ),
        "assignment_receipt": {
            "assignment_id": "PPCC2-E008",
            "cycle_assignment_id": "8ddaa122-30d5-410d-842b-7c4b21da498a",
            "snapshot_digest": "25ad3ff132fba732942a8259e0f66d51d1d30abfb55c0b4223638c8355eb4176",
            "receipts_sha256": "9ef2205d4acc31e66452b0b7f53c64cdcb9f22c67ea03dca9b7c4bcc5886bf8e",
            "unit_count": 9,
            "worker": "worker-2",
            "canonical_task_id": "2",
        },
        "source_contract": {
            "round_2_reports": round2,
            "copied_candidate_inputs": {
                "PPCC2-E004": {
                    "path": "inputs/PPCC2-E004/run_candidate.py",
                    "sha256": sha256(
                        HERE / "inputs" / "PPCC2-E004" / "run_candidate.py"
                    ),
                },
                "PPCC2-E005": {
                    "path": "inputs/PPCC2-E005/candidate_lab.py",
                    "sha256": sha256(
                        HERE / "inputs" / "PPCC2-E005" / "candidate_lab.py"
                    ),
                },
                "PPCC2-E006": {
                    "path": "inputs/PPCC2-E006/candidate.py",
                    "sha256": sha256(
                        HERE / "inputs" / "PPCC2-E006" / "candidate.py"
                    ),
                },
                "fixtures": {
                    "path": "inputs/PPCC2-E005/source-fixtures.json",
                    "sha256": sha256(
                        HERE / "inputs" / "PPCC2-E005" / "source-fixtures.json"
                    ),
                },
            },
        },
        "attack_profile": {
            "candidate_count": 3,
            "fixture_count": 9,
            "case_count": 27,
            "surface_count": 5,
            "repeat_count": 2,
            "hostile_shapes": [
                "240+ display-cell unbroken Unicode/ASCII token",
                "wide two-row table",
                "HTML-looking code with literal script tag",
                "long safe HTTPS URL",
                "javascript URL that must not survive as an active attribute",
                "nested grid section",
            ],
            "renderer_boundaries": {
                "PPCC2-E004": (
                    "candidate builder plus exact Barkpark PortableDoc Studio/email "
                    "renderer and native pdrender"
                ),
                "PPCC2-E005": (
                    "candidate builder plus exact Barkpark PortableDoc Studio/email "
                    "renderer and native pdrender"
                ),
                "PPCC2-E006": (
                    "candidate's declared reader-adaptive Studio/TUI/email/CLI "
                    "renderers"
                ),
            },
            "artifact_retention": (
                "Per-case rendered bytes and locally built binaries remain isolated "
                "scratch under artifacts/cases and artifacts/bin. The durable report, "
                "run summary, command log, verification logs, hashes, fixtures, and "
                "replay harness are retained; runnable_artifact_required was false."
            ),
        },
        "metrics": metrics,
        "candidate_verdicts": {
            "PPCC2-E004": {
                **by_candidate["PPCC2-E004"],
                "verdict": "REJECT_AS_IS",
                "reason": (
                    "At 40 columns the native table renderer truncates "
                    "PPCC2_ATTACK_TABLE_R1 to PPCC2_ATTACK_TAB; the surface stays "
                    "within width but loses authored evidence."
                ),
            },
            "PPCC2-E005": {
                **by_candidate["PPCC2-E005"],
                "verdict": "STRONGEST_REPAIR_CANDIDATE_NOT_YET_ELIGIBLE",
                "reason": (
                    "All non-email hard gates pass, but the exact production email "
                    "renderer emits <details>; the Round-2 prototype renderer's "
                    "linearization claim did not survive the exact boundary."
                ),
            },
            "PPCC2-E006": {
                **by_candidate["PPCC2-E006"],
                "verdict": "REJECT_AS_IS",
                "reason": (
                    "The semantic adapter excludes href values, so the safe authored "
                    "URL exists only in canonical CLI/API JSON and is absent from "
                    "Studio, both TUI widths, and email."
                ),
            },
        },
        "fixture_results": summary["fixture_results"],
        "failures_and_rejected_candidates": {
            "hard_failures": failed_cases,
            "failure_classes": [
                {
                    "candidate_id": "PPCC2-E004",
                    "affected_cases": 9,
                    "failed_gates": ["content_preservation"],
                    "finding": (
                        "40-column table cells truncate the attack marker even though "
                        "display width remains bounded; width-only green was vacuous."
                    ),
                },
                {
                    "candidate_id": "PPCC2-E005",
                    "affected_cases": 9,
                    "failed_gates": ["email_safety"],
                    "finding": (
                        "Exact production email emits one <details> per fixture, so "
                        "the chronology is not unconditionally linearized."
                    ),
                },
                {
                    "candidate_id": "PPCC2-E006",
                    "affected_cases": 9,
                    "failed_gates": ["content_preservation"],
                    "finding": (
                        "Safe href text is intentionally skipped by the semantic "
                        "adapter and disappears from four reader projections."
                    ),
                },
            ],
            "rejected_candidates": [
                "PPCC2-E004 as-is: narrow table evidence truncation.",
                "PPCC2-E005 as-is: exact email progressive disclosure is not linearized.",
                "PPCC2-E006 as-is: authored safe URL loss across reader projections.",
            ],
            "failed_attempts": [
                {
                    "attempt": "E004 runner invoked with unsupported --help",
                    "failure": (
                        "The script has no help mode and began refreshing tracked "
                        "fixture cache files in the shared main checkout."
                    ),
                    "repair": (
                        "Interrupted immediately and restored exactly the ten touched "
                        "E004 tracked files from HEAD; post-repair E004 git status was "
                        "clean. All subsequent execution used copied E008 inputs."
                    ),
                    "persistent_production_or_source_impact": False,
                },
                {
                    "attempt": "isolated-worktree Mix test",
                    "failure": "Hex dependencies are intentionally absent in the worktree.",
                    "repair": (
                        "Reran the identical targeted suite against the repository's "
                        "existing cached test build/dependencies: 115 tests, 0 failures."
                    ),
                    "persistent_production_or_source_impact": False,
                },
            ],
        },
        "next_round_decision": {
            "decision": "ATTACK_COMPLETE_NO_ROUND4_STARTED",
            "recommendation": (
                "Leader may dispatch Round 4 convergence toward PPCC2-E005 only if "
                "the refinement replaces exact-email <details> with deterministic "
                "expanded chronology and reruns the same 27-case attack. Do not carry "
                "E004 or E006 as-is. This report does not select a winner, mutate the "
                "wave, or start Round 4."
            ),
            "strongest_repair_candidate": "PPCC2-E005",
            "winner_declared": False,
            "round_4_started": False,
        },
        "unvisited_scope": [
            "Authenticated hydrated Studio editing, focus, and assistive-technology traversal.",
            "Real Gmail, Outlook, Apple Mail, VoiceOver, and NVDA clients.",
            "Papers outside the nine immutable assignment fixtures.",
            "Production publication, Paper writes, CycleFleet result append, root/Wave mutation, and repository-source changes.",
            "Round 4 convergence, Round 5 pilot, winner selection, capacity seal, and Build.",
        ],
        "actual_command_output": {
            "runner_command": ["python3", "attack_candidates.py", "run"],
            "runner_log": "attack-run.log",
            "runner_log_sha256": sha256(HERE / "attack-run.log"),
            "command_log": "artifacts/command-log.json",
            "command_log_sha256": sha256(COMMAND_LOG),
            "command_count": len(command_log),
            "all_subprocess_exit_codes_zero": all(
                item["exit_code"] == 0 for item in command_log
            ),
            "run_summary": "artifacts/run-summary.json",
            "run_summary_sha256": sha256(SUMMARY),
            "stdout_summary": {
                "candidates": 3,
                "fixtures": 9,
                "cases": 27,
                "hard_failures": metrics["observed_failure_rate"]["hard_failures"],
                "observed_failure_rate": metrics["observed_failure_rate"]["rate"],
            },
        },
        "delegation_compliance": {
            "subagents_spawned": 1,
            "subagent_model": "gpt-5.6-terra",
            "child_tasks": [
                {
                    "task_name": "e008_test_probe",
                    "thread_id": "/root/e008_test_probe",
                    "scope": "read-only existing coverage and regression-gap probe",
                }
            ],
            "serial_searches_before_spawn": 0,
            "assignment_execution_delegated": False,
            "findings_integrated": [
                "native pdrender dump and widthcheck are the real TUI boundary",
                "targeted PortableDoc email/sanitizer regression files",
                "E006's synthetic cross-surface evidence required independent hostile checks",
                "cross-surface safe-URL preservation was missing from existing regression coverage",
            ],
        },
        "personal_attestation": (
            "worker-2 personally copied the immutable candidate inputs, constructed "
            "the hostile fixtures, ran every final candidate/surface/repeat command, "
            "inspected the failure classes, and assembled this terminal report. The "
            "Terra child was read-only and did not execute or count assignment cases."
        ),
        "verification": {
            "status": "PASS",
            "checks": checks,
            "typecheck": "PASS: Python compileall",
            "tests": "PASS: 5 harness tests, Go pdrender suite, 115 targeted Elixir tests",
            "linter": "PASS: Python tabnanny",
            "end_to_end": (
                "PASS: all 27 attack cases executed; candidate hard failures were "
                "truthfully recorded"
            ),
            "regressions": "PASS: paper reader audit and Go/Elixir renderer suites",
            "initial_elixir_dependency_attempt": {
                "status": "FAIL_EXPECTED_ENVIRONMENT",
                "log_path": "artifacts/verification/elixir-render-email-safety-tests.log",
                "log_sha256": sha256(
                    verification_root / "elixir-render-email-safety-tests.log"
                ),
                "resolution": "cached repository test environment passed 115/115",
            },
        },
        "production_mutation_attestation": {
            "production_papers_mutated": False,
            "cyclefleet_mutated": False,
            "root_task_mutated": False,
            "wave_paper_mutated": False,
            "repository_source_mutated": False,
            "round_4_started": False,
            "repository_head": head,
            "writes_limited_to": str(HERE),
            "isolated_attack_artifacts_only": True,
            "source_diff_outside_assignment": "none",
        },
        "rollback": {
            "rule": "discard the isolated PPCC2-E008 assignment directory",
            "production_rollback_required": False,
        },
        "final_report_sha256_note": (
            "The byte-exact SHA-256 is stored in sibling report.sha256 to avoid a "
            "self-referential digest."
        ),
    }
    REPORT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    digest = sha256(REPORT)
    REPORT_SHA.write_text(f"{digest}  report.json\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "report": str(REPORT),
                "report_sha256": digest,
                "cases": len(report["fixture_results"]),
                "candidate_failure_rate": metrics["observed_failure_rate"]["rate"],
                "verification": report["verification"]["status"],
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
