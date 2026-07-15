#!/usr/bin/env python3
"""Capture only real HTML Studio/public readers and the built manifest-driven bp CLI."""
from __future__ import annotations

import argparse, http.cookiejar, json, os, subprocess
from pathlib import Path
from urllib.request import HTTPCookieProcessor, Request, build_opener

from common import CANDIDATE_DIGEST, ROOT, SURFACES, canonical_bytes, physical_hash, require, sha256_bytes, write_json


def main() -> None:
    p=argparse.ArgumentParser(); p.add_argument("--surfaces",default=",".join(SURFACES)); p.add_argument("--require-real-readers",action="store_true",required=True); a=p.parse_args()
    require(tuple(a.surfaces.split(","))==SURFACES,"exact E22 surfaces required")
    manifest=json.loads((ROOT/"deployment-manifest.json").read_text()); require(manifest["status"]=="ACTIVE" and manifest["record_count"]==36,"active 36-record deployment required")
    base=os.environ["E22_ISOLATED_BASE_URL"].rstrip("/"); token=os.environ["E22_ADMIN_TOKEN"]
    jar=http.cookiejar.CookieJar(); opener=build_opener(HTTPCookieProcessor(jar))
    mint=opener.open(Request(base+"/v1/auth/login-tickets",data=b"{}",headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"},method="POST"),timeout=30)
    ticket=json.loads(mint.read())["ticket"]
    studio=opener.open(base+"/login/ticket/"+ticket,timeout=30); studio_url=studio.geturl(); studio_body=studio.read()
    require(studio_url.rstrip("/").endswith("/studio"),"Studio ticket did not terminate at /studio")
    require(b"Sign in" not in studio_body and b"/login" not in studio_body[:2048],"anonymous or redirected Studio rejected")
    require(b"phx-" in studio_body or b"data-phx" in studio_body,"API/proxy substitute rejected: no LiveView Studio markers")
    rows=[]
    for rec in manifest["records"]:
        fixture,slug=rec["fixture_id"],rec["slug"]
        require(slug.encode() in studio_body or fixture.encode() in studio_body, f"Studio did not render fixture provenance {fixture}")
        public=opener.open(base+"/papers/"+slug,timeout=30); public_body=public.read()
        require(public.status==200 and public_body.strip(),f"blank public reader {fixture}")
        require(slug.encode() in public_body or fixture.encode() in public_body,f"public reader provenance missing {fixture}")
        cli=subprocess.run(["bp","-s",base,"--token",token,"paper","view",slug,"-o","json"],capture_output=True,check=False,timeout=30)
        require(cli.returncode==0 and cli.stdout.strip(),f"manifest-driven CLI failed {fixture}")
        for surface,body,meta in (("authenticated_studio",studio_body,{"reader":"liveview_html","authenticated":True}), ("public_reader",public_body,{"reader":"/papers/:slug","status":public.status}), ("cli",cli.stdout,{"reader":"bp paper view","returncode":cli.returncode})):
            require(base.encode() not in body,"URL reflection rejected")
            rel=Path("captures")/surface/f"{slug}.json"
            capture={"schema_version":"legendary-e22-capture/v1","fixture_id":fixture,"slug":slug,"surface":surface,"deployment_id":manifest["deployment_id"],"candidate_digest":CANDIDATE_DIGEST,"body_sha256":sha256_bytes(body),"body_bytes":len(body),"semantic_nonblank":bool(body.strip()),"proxy_derived":False,"url_reflected":False,"metadata":meta}
            write_json(ROOT/rel,capture); rows.append({"fixture_id":fixture,"surface":surface,"path":str(rel),"capture_sha256":physical_hash(ROOT/rel)})
    require(len({(r["fixture_id"],r["surface"]) for r in rows})==108,"missing or duplicate cells")
    rows.sort(key=lambda r:(r["fixture_id"],r["surface"]))
    write_json(ROOT/"capture-index.json",{"schema_version":"legendary-e22-capture-index/v1","assignment_id":"E22","rows":rows,"attempt_count":108,"accepted_capture_count":108,"blocked_cells":0,"missing_cells":0,"duplicate_cells":0,"blank_cells":0,"proxy_cells":0,"url_reflection_cells":0})
    write_json(ROOT/"session-manifest.json",{"schema_version":"legendary-e22-session/v1","assignment_id":"E22","deployment_id":manifest["deployment_id"],"studio_authenticated":True,"studio_anonymous":False,"studio_redirected":False,"login_ticket_minted":True,"login_ticket_persisted":False,"public_reader_session":"anonymous","cli_invocations":36,"secrets_persisted":False})
    print("E22 CAPTURE PASS cells=108 studio=36 public=36 cli=36")


if __name__=="__main__": main()
