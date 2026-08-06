#!/bin/bash
for t in "$@"; do
  echo "=== $t"
  bp task get "$t" -o json 2>&1 | python3 -c "
import json,sys
raw=sys.stdin.read()
try:
  d=json.loads(raw)
except Exception as e:
  print(' ERR', raw[:300]); sys.exit()
doc=d.get('doc',d)
c=doc.get('content') or {}
ac=c.get('acceptance_criteria') or doc.get('acceptance_criteria') or []
cl=doc.get('claim') or {}
now=cl.get('now') or c.get('now')
if isinstance(now,dict): now=now.get('text') or json.dumps(now)
print(' lifecycle:',doc.get('lifecycle_status'),'| worker:',cl.get('worker'),'| epoch:',cl.get('epoch'),'| progress:',doc.get('criteria_progress'))
print(' now:',(now or '')[:260])
print(' criteria met:',sum(1 for x in ac if x.get('met')),'/',len(ac))
for i,x in enumerate(ac):
  if not x.get('met'): print('  OPEN',i,(x.get('criterion') or '')[:130])
  elif not (x.get('evidence') or '').strip(): print('  MET-NO-EVIDENCE',i,(x.get('criterion') or '')[:100])
"
done
