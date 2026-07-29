#!/usr/bin/env python3
import json
from pathlib import Path
p=Path(__file__).parent/"report.json"; r=json.loads(p.read_text())
required={"portable_doc_schema_validity","studio_structural_completeness","tui_width","email_safety","cli_api_round_trip","accessibility","content_preservation","pilot_gate_pass_rate","observed_failure_rate","batch_capacity","rollback"}
assert r["assignment_id"]=="PPCC2-E012" and r["round"]==4 and r["status"]=="completed"
assert set(r["metrics"])==required
assert r["cycle_assignment_id"]=="51d48d9d-f661-4e0e-88dc-351e19eb04d5"
assert r["snapshot_digest"]=="b7067c8d2bb2fe74ac22c09841f075965c56d4e73d19744f5251f0e9b89fcceb"
assert r["receipts_sha256"]=="7bad1c6d43d6804498a980da6461b3d2ac926897fcb442c8e9bb13980235c09f"
assert r["production_mutation_attestation"]["round_5_started"] is False
assert r["next_round_decision"]["winner_declared"] is False
assert r["unvisited_scope"] and r["failures_and_rejected_candidates"]
assert r["verification"]["status"] == "PASS" and all(check["status"] == "PASS" for check in r["verification"]["checks"])
print(json.dumps({"assignment_id":"PPCC2-E012","required_metrics":len(required),"status":"PASS"},sort_keys=True))
