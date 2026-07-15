#!/usr/bin/env python3
import hashlib,json,subprocess,sys,tempfile,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]; SCRIPT=ROOT/'scripts/build_candidate.py'; OUTPUT=ROOT/'output/repair-packet.json'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def stable(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def main():
    timings=[]; hashes=[]
    transform_hashes=[]; failures=[]
    with tempfile.TemporaryDirectory(prefix='e04-replay-') as tmp:
        tmp=Path(tmp)
        for i in range(2):
            output=tmp/f'repair-packet-{i}.json'; transformations=tmp/f'transformations-{i}.json'
            t=time.perf_counter()
            subprocess.run([sys.executable,str(SCRIPT),'--output',str(output),'--transformations-output',str(transformations)],check=True,capture_output=True,text=True)
            timings.append(round(time.perf_counter()-t,6)); hashes.append(sha(output)); transform_hashes.append(sha(transformations))
        p=json.load((tmp/'repair-packet-0.json').open()); tm=json.load((tmp/'transformations-0.json').open())
    if hashes[0]!=sha(OUTPUT): failures.append('committed-packet-drift')
    if transform_hashes[0]!=sha(ROOT/'transformation-manifest.json'): failures.append('committed-transformations-drift')
    if hashes[0]!=hashes[1] or transform_hashes[0]!=transform_hashes[1]: failures.append('replay-byte-drift')
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
    result={"status":"PASS" if not failures else "FAIL","accepted_paper_and_adversarial_count":len(p['papers']),"task_count":len(p['tasks']),"quarantine_count":len(p['quarantine']),"total_fixture_count":total,"class_count":len(classes),"first_sha256":hashes[0],"second_sha256":hashes[1],"first_transformations_sha256":transform_hashes[0],"second_transformations_sha256":transform_hashes[1],"idempotent":hashes[0]==hashes[1] and transform_hashes[0]==transform_hashes[1],"timings_seconds":timings,"timing_policy":"volatile replay timing is stdout-only; committed measured timing is frozen in verification.json and excluded from regenerated deterministic bytes","failures":failures}
    print('E04 VERIFY '+result['status']); print(json.dumps(result,sort_keys=True)); return 0 if result['status']=='PASS' else 1
if __name__=='__main__': raise SystemExit(main())
