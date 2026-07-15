#!/usr/bin/env python3
import hashlib,json,subprocess,sys,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]; SCRIPT=ROOT/'scripts/build_candidate.py'; OUTPUT=ROOT/'output/repair-packet.json'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def stable(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def main():
    timings=[]; hashes=[]
    for _ in range(2):
        t=time.perf_counter(); subprocess.run([sys.executable,str(SCRIPT)],check=True,capture_output=True,text=True); timings.append(round(time.perf_counter()-t,6)); hashes.append(sha(OUTPUT))
    p=json.load(OUTPUT.open()); failures=[]
    tm=json.load((ROOT/'transformation-manifest.json').open())
    if len(tm.get('units',[]))!=36: failures.append('transformation-manifest-count')
    if p.get('schema_version')!='legendary-e04-repair-packet/v1' or p.get('assignment_id')!='E04': failures.append('packet-schema')
    for u in p['papers']:
        if u['semantic_hash_before']!=u['semantic_hash_after']: failures.append(f"semantic:{u['id']}")
        if u['unsupported_terminal_nodes']: failures.append(f"unsupported:{u['id']}")
        if not u['derived_html'].strip(): failures.append(f"blank:{u['id']}")
        if hashlib.sha256(stable(u['preimage']).encode()).hexdigest()!=u['preimage_sha256']: failures.append(f"rollback:{u['id']}")
    classes=set()
    for u in p['tasks']:
        classes.add(u['class'])
        if set(u['canonical_fields'])!=set(u['required_fields']): failures.append(f"task-contract:{u['id']}")
        if hashlib.sha256(stable(u['preimage']).encode()).hexdigest()!=u['preimage_sha256']: failures.append(f"rollback:{u['id']}")
    for u in p['quarantine']:
        if hashlib.sha256(stable(u['preimage']).encode()).hexdigest()!=u['preimage_sha256']: failures.append(f"quarantine-rollback:{u['id']}")
    if len(classes)!=6: failures.append('class-flattening')
    total=len(p['papers'])+len(p['tasks'])+len(p['quarantine'])
    if total!=36: failures.append(f'fixture-count:{total}')
    result={"status":"PASS" if not failures and hashes[0]==hashes[1] else "FAIL","accepted_paper_and_adversarial_count":len(p['papers']),"task_count":len(p['tasks']),"quarantine_count":len(p['quarantine']),"total_fixture_count":total,"class_count":len(classes),"first_sha256":hashes[0],"second_sha256":hashes[1],"idempotent":hashes[0]==hashes[1],"timings_seconds":timings,"failures":failures}
    (ROOT/'verification.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
    print('E04 VERIFY '+result['status']); print(json.dumps(result,sort_keys=True)); return 0 if result['status']=='PASS' else 1
if __name__=='__main__': raise SystemExit(main())
