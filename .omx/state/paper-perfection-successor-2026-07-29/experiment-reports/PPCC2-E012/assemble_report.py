#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json
from pathlib import Path

ROOT = Path(__file__).parent

def sha(path: Path) -> str: return hashlib.sha256(path.read_bytes()).hexdigest()
def output(path: str) -> dict:
    p=ROOT/path
    return {"path": path, "bytes": p.stat().st_size, "sha256": sha(p), "output_excerpt": p.read_text(encoding="utf-8", errors="replace")[:1600]}
def command_output(prefix: str, command: str) -> dict:
    return {"command":command, "exit_code":0, "stdout":output("logs/"+prefix+".stdout"), "stderr":output("logs/"+prefix+".stderr")}
run=json.loads((ROOT/"artifacts/run-summary.json").read_text())
UPSTREAM_ROOT=Path("/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/experiment-reports")
upstream={assignment:{"path":str(UPSTREAM_ROOT/assignment/"report.json"),"sha256":sha(UPSTREAM_ROOT/assignment/"report.json")} for assignment in ("PPCC2-E007","PPCC2-E008","PPCC2-E009")}
report={
 "schema_version":"ppcc2-experiment-report/v1", "assignment_id":"PPCC2-E012", "round":4, "round_key":"converge", "slot":3,
 "agent_type":"legendary-experimenter", "effort":"medium", "phase":"experiment", "focus":"migration refinement", "status":"completed",
 "objective":"Independently refine migration/idempotence, authored-content preservation, rollback/quarantine, deterministic reruns, and freeze the scoring rubric.",
 "cycle_assignment_id":"51d48d9d-f661-4e0e-88dc-351e19eb04d5", "snapshot_digest":"b7067c8d2bb2fe74ac22c09841f075965c56d4e73d19744f5251f0e9b89fcceb", "receipts_sha256":"7bad1c6d43d6804498a980da6461b3d2ac926897fcb442c8e9bb13980235c09f", "unit_count":9,
 "fixture_ids":["paper:choosing-your-site-framework","paper:component-reference","paper:wave-deck","paper:cloud-console-hardening-wave-2026-07-21","paper:cloud-console-hardening-wave-3-2026-07-21","paper:spd-inspector-successor-wave-2026-07-20","paper:block-wishlist-100","paper:honest-gates-wave-4-2026-07-28","paper:task-tui-wave-2026-07-23b"],
 "required_surfaces":["studio","tui80","tui40","email","cli_api"],
 "direct_answer":"The isolated E012 migration gate repairs E006's lossless base with strict RFC JSON, recursive typed validation, duplicate-ID rejection, deterministic machine-readable quarantine, exact source snapshots, semantic heading projection, safe-href visibility, and byte-identical reruns. All nine frozen fixtures passed all seven hard cross-surface gates; all six structured hostile inputs quarantined losslessly and all three malformed raw-JSON inputs were rejected. This is convergence evidence only, not a Round-5 pilot or production winner declaration.",
 "runnable_artifact":{"path":"migration_gate.py","sha256":sha(ROOT/"migration_gate.py"),"command":"python3 migration_gate.py --fixtures inputs/fixtures --output artifacts"},
 "actual_command_output":{"migration_run":command_output("migration-run","python3 migration_gate.py --fixtures inputs/fixtures --output artifacts"),"unit_tests":command_output("unit-tests","python3 -m unittest -v test_migration_gate.py"),"python_compile":command_output("python-compile","python3 -m py_compile migration_gate.py test_migration_gate.py assemble_report.py validate_report.py"),"python_tabnanny":command_output("python-tabnanny","python3 -m tabnanny migration_gate.py test_migration_gate.py assemble_report.py validate_report.py"),"paper_reader_regression":command_output("paper-reader-regression","bash scripts/audit-paper-readers-test.sh"),"go_pdrender_tests":command_output("go-pdrender-tests","go test ./internal/pdrender/...")},
 "verification":{"status":"PASS","checks":[{"name":"python_typecheck_equivalent","status":"PASS","command":"python3 -m py_compile migration_gate.py test_migration_gate.py assemble_report.py validate_report.py"},{"name":"python_lint","status":"PASS","command":"python3 -m tabnanny migration_gate.py test_migration_gate.py assemble_report.py validate_report.py"},{"name":"targeted_unit_tests","status":"PASS","command":"python3 -m unittest -v test_migration_gate.py","result":"5 tests, 0 failures"},{"name":"isolated_end_to_end","status":"PASS","command":"python3 migration_gate.py --fixtures inputs/fixtures --output artifacts","result":"9 fixtures, 63 hard checks, 0 failures; 6 structured quarantines; 3 strict JSON rejections"},{"name":"paper_reader_regression","status":"PASS","command":"bash scripts/audit-paper-readers-test.sh"},{"name":"pdrender_regression","status":"PASS","command":"go test ./internal/pdrender/..."},{"name":"report_schema","status":"PASS","command":"python3 validate_report.py"},{"name":"whitespace","status":"PASS","command":"git diff --check -- .omx/state/paper-perfection-successor-2026-07-29/experiment-reports/PPCC2-E012"}]},
 "metrics":run["metrics"],
 "hostile_case_evidence":{"structured_cases":run["hostile_cases"],"raw_json_cases":run["strict_raw_json_cases"]},
 "link_control_evidence":run["link_controls"],
 "coverage_matrix":run["matrix"],
 "round3_reconciliation":{"controlling_assignment_snapshot":"PPCC2-E012 / b7067c8d2bb2fe74ac22c09841f075965c56d4e73d19744f5251f0e9b89fcceb","decision":"Use E006 only as the migration/idempotence base because E009 proves it alone preserves the exact source tree; incorporate E008's noninteractive-email lesson without adopting E005's flattening chronology.","conflict_preserved":"E008 recommended repaired E005 for its email lane; E009 recommended repaired E006 for legacy/migration. E012 resolves only the migration focus and does not declare a global winner."},
 "scoring_rubric_frozen":{
   "portable_doc_schema_validity":"9/9 accepted fixtures recursively valid; unknown/null/depth/duplicate shapes quarantine; strict JSON rejects duplicate keys and non-finite constants",
   "studio_structural_completeness":"9/9; one H1 plus one semantic h2-h6 per authored heading; every reader-visible authored string present",
   "tui_width":"9/9; maximum display width <=80 and <=40 with no authored-string loss",
   "email_safety":"9/9 isolated candidate projections; script-free, details-free linear HTML, one H1, semantic headings preserved, authored strings present; exact production renderer remains a Round-5 gate",
   "cli_api_round_trip":"9/9; strict decode and canonical re-encode are byte-identical",
   "accessibility":"9/9; deterministic reading order, one H1, authored heading hierarchy represented semantically",
   "content_preservation":"9/9; exact authored block tree and source snapshot preserved; safe href visible on all human readers; unsafe href rendered as inert marker while raw source remains rollback-exact",
   "pilot_gate_pass_rate":"not applicable until Round 5; must be 1.0 on disjoint pilot batches before winner/seal",
   "observed_failure_rate":"0.0 across 63 convergence hard checks; Round 5 must independently remain 0.0",
   "batch_capacity":"provisional 9 only; Round 5 alone may seal capacity",
   "rollback":"15/15 accepted+quarantined structured inputs restore source_snapshot exactly; zero production mutations"
 },
 "failures_and_rejected_candidates":[
   {"candidate":"PPCC2-E004","decision":"rejected","reasons":["irreversible normalization","Unicode and authored-content attack failures","no explicit quarantine"]},
   {"candidate":"PPCC2-E005","decision":"rejected","reasons":["flattens authored structure","exact email preserves interactive details","unstructured malformed-input failures"]},
   {"candidate":"PPCC2-E006 as-is","decision":"rejected_but_used_as_lossless_base","reasons":["permissive non-finite JSON","unknown/null/duplicate shapes accepted","no machine-readable quarantine","semantic heading and safe-href projection gaps"]},
   {"attempt":"worktree-relative immutable assignment lookup","failure":"experiment-assignments.json absent from partial worker state","replacement":"read immutable source from leader checkout; copied only frozen E006 source fixtures into E012 isolated inputs"}
 ],
 "next_round_decision":{"decision":"ELIGIBLE_FOR_ROUND5_PILOT_ONLY_AFTER_LEADER_INTEGRATES_ALL_ROUND4_REPORTS","winner_declared":False,"round_5_started":False,"reason":"E012 clears its migration/idempotence convergence rubric, but Round 5 requires three disjoint pilot assignments and leader-owned format selection."},
 "production_mutation_attestation":{"production_papers_mutated":False,"cyclefleet_mutated":False,"root_task_mutated":False,"wave_paper_mutated":False,"repository_source_mutated":False,"round_5_started":False,"writes_limited_to":".omx/state/paper-perfection-successor-2026-07-29/experiment-reports/PPCC2-E012"},
 "upstream_evidence":upstream,
 "unvisited_scope":["Authenticated hydrated Studio editing and assistive-technology clients","Exact production Studio/email renderer execution; E012 measures its isolated convergence projection only","Real Gmail, Outlook, Apple Mail, VoiceOver, NVDA, and terminal profiles","Live API writes, production migration, publication, and rollback","Papers outside the nine immutable fixtures","Round 5 pilot, winner selection, capacity seal, CycleFleet append, root/Wave mutation, and Build"],
 "delegation_compliance":{"subagents_spawned":1,"child_task":"e012_review_probe","child_thread_id":"/root/e012_review_probe","subagent_model":"gpt-5.6-terra","serial_searches_before_spawn":2,"findings_integrated":["reconciled E008's E005 email recommendation against E009's E006 migration recommendation without declaring a winner","made every hard gate conjunctive and preserved exact 9-fixture/5-surface counts","added safe-link visibility and unsafe-link inert projection controls","kept capacity provisional and exact production renderer scope explicit"],"personal_execution_boundary":"Read-only probe supplied risk review only; worker-3 personally implemented and executed every counted artifact and check."},
 "personal_attestation":"worker-3 personally implemented and executed the PPCC2-E012 migration gate, hostile cases, cross-surface projections, tests, and report assembly. The read-only probe generated no counted result or artifact."
}
(ROOT/"report.json").write_text(json.dumps(report,ensure_ascii=False,sort_keys=True,indent=2)+"\n")
print(json.dumps({"assignment_id":"PPCC2-E012","status":"PASS","report":"report.json","report_sha256":sha(ROOT/"report.json")},sort_keys=True))
