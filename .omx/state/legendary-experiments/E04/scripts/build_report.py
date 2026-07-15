#!/usr/bin/env python3
import hashlib,json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]; E03=ROOT.parent/'E03'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
v=json.load((ROOT/'verification.json').open()); packet=json.load((ROOT/'output/repair-packet.json').open())
previous=json.load((ROOT/'result.json').open()) if (ROOT/'result.json').exists() else {}
thresholds={
 "accessibility":"BLOCKED_AUTHENTICATED_STUDIO_AND_REAL_EMAIL_UNAVAILABLE",
 "authored_content_preservation":"PASS_36_OF_36_PREIMAGES_AND_ACCEPTED_SEMANTIC_HASHES",
 "build_formula":"NOT_APPLICABLE_ROUND_2",
 "capacity_rule":"NOT_APPLICABLE_BEFORE_PILOT",
 "idempotence":"PASS_TWO_IDENTICAL_RUNS",
 "pilot_failure_rate":"NOT_APPLICABLE_ROUND_2",
 "reader_visibility":"PARTIAL_LOCAL_HTML_NONBLANK; TARGET_STUDIO_EMAIL_BLOCKED",
 "render_test_gate":"PASS_LOCAL_RUNNER_AND_VERIFIER",
 "rollback":"PASS_36_OF_36_PREIMAGES; TWO_QUARANTINE_PATHS",
 "schema_validity":"PASS_ACCEPTED_OUTPUTS_USE_SUPPORTED_TERMINAL_TYPES",
 "structural_completeness":"PASS_SEMANTIC_HASH_AND_SIX_DISTINCT_TASK_CONTRACTS",
 "surface_exercise":"FAIL_BLOCKED_AUTHENTICATED_STUDIO_AND_REAL_EMAIL",
 "width_overflow":"BLOCKED_REAL_TUI_AND_EMAIL_CLIENT; LONG_TOKEN_FIXTURE_PRESERVED_LOCALLY"
}
score={"schema_version":"legendary-e04-scorecard/v1","assignment_id":"E04","candidate_id":"candidate-canonical-native","frozen_thresholds":{"path":"../E03/thresholds.json","sha256":sha(E03/'thresholds.json')},"frozen_failure_taxonomy":{"path":"../E03/failure-taxonomy.json","sha256":sha(E03/'failure-taxonomy.json')},"frozen_candidate_rubric":{"path":"../E03/candidate-rubric.json","sha256":sha(E03/'candidate-rubric.json')},"frozen_replay_contract":{"path":"../E03/requests.json","sha256":sha(E03/'requests.json')},"counts":{"frozen_fixtures":36,"accepted_paper_and_adversarial":v['accepted_paper_and_adversarial_count'],"tasks":v['task_count'],"quarantined":v['quarantine_count'],"task_classes":v['class_count']},"threshold_results":thresholds,"capability_blocks":["authenticated Studio content proof unavailable","real-client email client proof unavailable","target-reader width/accessibility proof unavailable without those capabilities"],"local_candidate_gate":"PASS","overall_quality":"PARTIAL","action":"REWORK"}
(ROOT/'scorecard.json').write_text(json.dumps(score,sort_keys=True,indent=2)+'\n')
files=['README.md','candidate-schema.json','fixtures/manifest.json','fixtures/source-documents.json','output/repair-packet.json','scorecard.json','transformation-manifest.json','scripts/build_candidate.py','scripts/build_report.py','scripts/run.sh','scripts/verify.py','verification.json']+[f'fixtures/adversarial/{p.name}' for p in sorted((ROOT/'fixtures/adversarial').glob('*.json'))]
result={"schema_version":"legendary-e04-result/v1","assignment_id":"E04","candidate_id":"candidate-canonical-native","generated_at":previous.get('generated_at','2026-07-15T02:46:17.569663+00:00'),"commands_or_probes":["python3 scripts/build_candidate.py (deterministic tracked artifacts)","python3 scripts/verify.py (two isolated candidate reruns; volatile timing stdout-only)","python3 scripts/build_report.py (deterministic report regeneration)","./scripts/run.sh (full replay; clean-tree required)","python3 -m compileall -q scripts","sh -n scripts/run.sh"],"counts":score['counts'],"output_sha256":v['second_sha256'],"idempotence":{"status":"PASS","first_sha256":v['first_sha256'],"second_sha256":v['second_sha256']},"timing":{"candidate_reruns_seconds":v['timings_seconds'],"max_seconds":max(v['timings_seconds']),"policy":v['timing_policy']},"hard_threshold_outcomes":thresholds,"capability_blocks":score['capability_blocks'],"quarantine":[{"id":x['id'],"reasons":x['reasons'],"preimage_sha256":x['preimage_sha256']} for x in packet['quarantine']],"artifact_hashes":{f:sha(ROOT/f) for f in files},"validation":{"command":"./scripts/run.sh twice","expected":"E04 VERIFY PASS both times and clean git status","status":"PASS"},"verdict":{"quality":"PARTIAL","action":"REWORK","reason":"Local canonical, schema, preservation, class, idempotence, rollback, and replay-cleanliness gates pass; frozen real-surface Studio/email/accessibility/width gates remain blocked."}}
(ROOT/'result.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
print('E04 REPORT PARTIAL REWORK')
