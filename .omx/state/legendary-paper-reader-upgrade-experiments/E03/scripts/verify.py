#!/usr/bin/env python3
"""Read-only idempotent E03 verifier."""
import hashlib, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def load(p): return json.loads((ROOT / p).read_text())
def cb(v): return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
def sh(b): return hashlib.sha256(b).hexdigest()

def main():
    a=load("assignment.json"); b=load("reports/baseline.json"); r=load("reports/render-matrix.json"); h=load("reports/history-provenance.json"); t=load("reports/thresholds.json"); f=load("reports/failure-taxonomy.json"); c=load("fixtures/controls.json"); k=load("fixtures/known-bad.json"); x=load("fixtures/adversarial.json"); m=load("reports/hash-manifest.json")
    checks=[]
    def ck(n,v,e):
        if v!=e: raise AssertionError(f"{n}: {v!r} != {e!r}")
        checks.append(n)
    ck("assignment",a["assignment_id"],"experiment-03"); ck("type",a["agent_type"],"legendary-experimenter"); ck("round",a["round"],1); ck("candidates",a["candidate_ids"],[]); ck("widths",a["widths"],[20,40,80,120]); ck("papers",len(a["papers"]),4)
    ck("render_cells",len(r["renders"]),32); ck("surface_cells",sorted(set((z["surface"],z["width"]) for z in r["renders"])),[(s,w) for s in ["human-cli","tui-equivalent"] for w in [20,40,80,120]])
    ck("revisions",sum(z["revision"]==next(p["revision"] for p in a["papers"] if p["fixture_id"]==z["fixture_id"]) for z in r["renders"]),32)
    ck("human_no_ansi",sum(not z["ansi_escape_present"] for z in r["renders"] if z["surface"]=="human-cli"),16); ck("tui_ansi",sum(z["ansi_escape_present"] for z in r["renders"] if z["surface"]=="tui-equivalent"),16)
    ck("history_rows",len(h["papers"]),4); ck("limit_failures",sum(not z["limit_forwarded"] for z in h["papers"]),4); ck("history_uuid",sum(bool(z["first_history_uuid"]) for z in h["papers"]),4)
    ck("thresholds",len(t["hard_thresholds"]),15); ck("taxonomy",len(f["observed"]),16); ck("controls",len(c["dimensions"]),10); ck("known_bad",len(k["targets"]),12); ck("adversarial",len(x["fixtures"]),8)
    ck("machine_error_nonzero",b["cli_error"]["exit_code"]!=0,True); ck("paper_help_width",b["navigation"]["width_flag"],True); ck("no_outline",b["navigation"]["outline_flag"],False); ck("no_pager",b["navigation"]["pager_flag"],False); ck("no_history",b["navigation"]["history_flag"],False)
    rows=[]
    for row in m["files"]:
        p=ROOT/row["path"]
        ck("exists:"+row["path"],p.is_file(),True); data=p.read_bytes(); ck("hash:"+row["path"],sh(data),row["sha256"]); ck("bytes:"+row["path"],len(data),row["bytes"]); rows.append(row)
    ck("artifact_set",sh(cb(rows)),m["artifact_set_sha256"])
    out={"schema_version":"legendary-paper-e03-verification/v1","status":"PASS","check_count":len(checks),"artifact_set_sha256":m["artifact_set_sha256"],"metrics":b["totals"]}
    print(json.dumps(out,sort_keys=True,separators=(",",":")))
if __name__=="__main__":
    try: main()
    except Exception as e: print("E03 VERIFY FAIL: "+str(e),file=sys.stderr); raise SystemExit(1)
