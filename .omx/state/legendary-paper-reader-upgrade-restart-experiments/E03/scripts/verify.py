#!/usr/bin/env python3
"""Pure replay verifier for restart E03; emits deterministic JSON."""
import hashlib, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def load(p): return json.loads((ROOT / p).read_text())
def cb(v): return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
def sh(b): return hashlib.sha256(b).hexdigest()

def main():
    a=load("assignment.json"); c=load("semantic/census.json"); r=load("reports/render-matrix.json"); g=load("reports/hard-gates.json")
    h=load("reports/hostile-errors.json"); n=load("reports/navigation-state-recovery.json"); z=load("reports/zero-external-mutation.json")
    t=load("reports/token-scan.json"); m=load("reports/artifact-hashes.json"); result=load("cycle-result.json")
    checks=[]
    def ck(name, actual, expected):
        if actual != expected: raise AssertionError(f"{name}: {actual!r} != {expected!r}")
        checks.append(name)
    ck("assignment",a["assignment_id"],"restart-experiment-03"); ck("uuid",a["cycle_assignment_id"],"6a716097-1b44-4775-8e8e-46b5d1a1a5b1")
    ck("round",a["round"],"baseline"); ck("type",a["agent_type"],"legendary-experimenter"); ck("server",a["server"],"guerrilla")
    ck("manifest",a["manifest"],"docs/cli/fixtures/full-manifest.json"); ck("papers",len(a["papers"]),4); ck("widths",a["widths"],[20,40,80,120])
    exact={"block_count":815,"table_count":46,"legacy_header_cells":113,"headerless_tables":11,"body_cells":1374,"callout_count":30,"mark_records":388,"exact_empty_spacers":381,"nested_list_items":11,"nested_list_words":406}
    for key,val in exact.items(): ck("denominator:"+key,c["totals"][key],val)
    ck("render-cells",len(r["cells"]),32); ck("render-keys",len({(x["fixture_id"],x["width"],x["profile"]) for x in r["cells"]}),32)
    ck("related-boundary",sum(x["appendix_present"] for x in r["cells"]),32); ck("navigation-cells",len(n["fresh_process_profile_pairs"]),16)
    ck("external-writes",z["external_writes_attempted"],0); ck("source-stable",z["all_equal"],True); ck("token-scan",t["status"],"PASS")
    ck("hostile-rows",len(h["rows"]),6); ck("500-block",h["not_induced"][0]["status"],"BLOCKED_SAFETY")
    ck("gate-count",len(g["gates"]),6); ck("typed-verdict",result["typed_verdict"],"FAIL"); ck("cycle-round",result["round"],"baseline")
    rows=[]
    for row in m["files"]:
        path=ROOT/row["path"]; ck("exists:"+row["path"],path.is_file(),True); data=path.read_bytes()
        ck("bytes:"+row["path"],len(data),row["bytes"]); ck("hash:"+row["path"],sh(data),row["sha256"]); rows.append(row)
    ck("artifact-set",sh(cb(rows)),m["artifact_set_sha256"])
    out={"schema_version":"restart-e03-verification/v1","status":"PASS","check_count":len(checks),
         "artifact_set_sha256":m["artifact_set_sha256"],"typed_verdict":result["typed_verdict"],"round":"baseline"}
    print(json.dumps(out,sort_keys=True,separators=(",", ":")))

if __name__=="__main__":
    try: main()
    except Exception as exc: print("RESTART E03 VERIFY FAIL: "+str(exc),file=sys.stderr); raise SystemExit(1)
