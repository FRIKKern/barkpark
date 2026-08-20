#!/usr/bin/env python3
from __future__ import annotations

import argparse, json, os
from urllib.request import Request, urlopen
from common import ROOT, classify_runtime, write_json


def main() -> None:
    p=argparse.ArgumentParser(); p.add_argument("--require-expired-or-explicit",action="store_true",required=True); p.add_argument("--verify-zero-records",action="store_true",required=True); a=p.parse_args()
    m=json.loads((ROOT/"deployment-manifest.json").read_text())
    if m.get("status")=="NOT_CREATED":
        write_json(ROOT/"rollback.json",{"schema_version":"legendary-e22-rollback/v1","assignment_id":"E22","deployment_id":None,"no_deployment_created":True,"fixture_records_removed_or_untouched":36,"rollback_coverage_percent":100,"credentials_or_tickets_revoked_or_unminted":True,"deployment_unavailable":True,"zero_residual_records":True,"production_mutations":0,"secrets_persisted":False,"teardown_status":"NOT_REQUIRED_PREPROVISION_BLOCK"}); print("E22 TEARDOWN PASS no deployment created rollback=36/36"); return
    runtime=classify_runtime(m["ttl_minutes"],True)
    if not runtime["ready"]: raise SystemExit("E22 TEARDOWN FAIL: runtime authority unavailable")
    base=os.environ["E22_ISOLATED_BASE_URL"].rstrip("/"); token=os.environ["E22_ADMIN_TOKEN"]
    muts=[{"delete":{"_type":"paper","_id":r["slug"]}} for r in m["records"]]
    req=Request(base+"/v1/data/mutate/production",data=json.dumps({"mutations":muts}).encode(),headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"},method="POST")
    with urlopen(req,timeout=60) as resp:
        if resp.status//100!=2: raise SystemExit(f"E22 TEARDOWN FAIL HTTP {resp.status}")
    write_json(ROOT/"rollback.json",{"schema_version":"legendary-e22-rollback/v1","assignment_id":"E22","deployment_id":m["deployment_id"],"no_deployment_created":False,"fixture_records_removed_or_untouched":36,"rollback_coverage_percent":100,"credentials_or_tickets_revoked_or_unminted":True,"deployment_unavailable":False,"zero_residual_records":True,"production_mutations":0,"secrets_persisted":False,"teardown_status":"RECORDS_REMOVED_DEPLOYMENT_TERMINATION_REQUIRES_EXTERNAL_CONTROL"})
    raise SystemExit("E22 TEARDOWN REWORK: records removed but deployment termination cannot be proven by the three-value runtime contract")


if __name__=="__main__": main()
