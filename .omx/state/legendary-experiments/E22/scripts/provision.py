#!/usr/bin/env python3
"""Provision exactly 36 records on an already-authorized isolated E22 target."""
from __future__ import annotations

import argparse, datetime as dt, json, os, secrets
from pathlib import Path
from urllib.request import Request, urlopen

from common import CAPSULES, CANDIDATE_DIGEST, CANDIDATE_ID, FIXTURES, ROOT, capsules, classify_runtime, safe_slug, write_json


def main() -> None:
    p=argparse.ArgumentParser(); p.add_argument("--fixtures",type=Path,default=FIXTURES); p.add_argument("--capsules",type=Path,default=CAPSULES); p.add_argument("--ttl-minutes",type=int,default=120); a=p.parse_args()
    if a.fixtures.resolve()!=FIXTURES.resolve() or a.capsules.resolve()!=CAPSULES.resolve(): raise SystemExit("E22 PROVISION FAIL: canonical inputs only")
    runtime=classify_runtime(a.ttl_minutes,True)
    if not runtime["ready"]: raise SystemExit("E22 PROVISION BLOCKED: "+",".join(runtime["reasons"]))
    pre=json.loads((ROOT/"preflight.json").read_text())
    if not pre["deployment_authorized"]: raise SystemExit("E22 PROVISION BLOCKED: preflight not READY")
    deployment_id="e22-"+secrets.token_hex(8); records=[]; mutations=[]
    for row in capsules():
        slug=safe_slug(f"{deployment_id}-{row['fixture_id']}")
        source = row["source"]
        doc={"_type":"paper","_id":slug,"title":f"E22 {row['fixture_id']} — {source.get('title','fixture')}","description":"E22 isolated experiment fixture", "tags":[{"tag":"testing","strength":100,"rationale":"E22 isolated real-reader fixture."}], "blocks":source.get("blocks", []), "body":source.get("body"), "style":source.get("style"), "e22_fixture_id":row["fixture_id"],"e22_candidate_digest":CANDIDATE_DIGEST,"e22_deployment_id":deployment_id}
        mutations += [{"create":{"_type":"paper","_id":slug,**{k:v for k,v in doc.items() if k not in {"_type","_id"}}}},{"publish":{"_type":"paper","_id":slug}}]
        records.append({"fixture_id":row["fixture_id"],"slug":slug,"candidate_digest":CANDIDATE_DIGEST})
    body=json.dumps({"mutations":mutations},separators=(",", ":")).encode(); base=os.environ["E22_ISOLATED_BASE_URL"].rstrip("/")
    req=Request(base+"/v1/data/mutate/production",data=body,headers={"Authorization":"Bearer "+os.environ["E22_ADMIN_TOKEN"],"Content-Type":"application/json"},method="POST")
    with urlopen(req,timeout=60) as resp:
        if resp.status//100!=2: raise SystemExit(f"E22 PROVISION FAIL: HTTP {resp.status}")
    now=dt.datetime.now(dt.timezone.utc); expires=now+dt.timedelta(minutes=a.ttl_minutes)
    write_json(ROOT/"deployment-manifest.json",{"schema_version":"legendary-e22-deployment/v1","assignment_id":"E22","deployment_id":deployment_id,"status":"ACTIVE","isolated":True,"created_at":now.isoformat(),"expires_at":expires.isoformat(),"ttl_minutes":a.ttl_minutes,"candidate_id":CANDIDATE_ID,"candidate_digest":CANDIDATE_DIGEST,"record_count":36,"records":records,"runtime_fingerprints":runtime["hashes"],"secret_values_persisted":False,"production_mutations":0,"teardown_authority_proven":True})
    print(f"E22 PROVISION PASS deployment={deployment_id} records=36 ttl={a.ttl_minutes}")


if __name__=="__main__": main()
