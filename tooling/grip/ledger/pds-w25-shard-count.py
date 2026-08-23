# Pinned GATE for the pds-w25 round shards: every manifest row of the named
# class must carry a well-formed disposition. Pages the corpus TO EXHAUSTION
# (stop on a short page — never a hardcoded ceiling: the server silently clamps
# limit>1000 and range(0,5000,...) was blind to every row past position 5000,
# measured 5000-of-6971 on 2026-08-22), guards each page against overflow,
# asserts the walk terminated, and prints EVERY failing row (bad[:15] made an
# operator fix fifteen, re-run, and red again on the sixteenth). Same pager
# shape as tooling/grip/seal.mjs (PR #12954).
import json,os,sys,time,urllib.error,urllib.request
cls=sys.argv[1]
mf=sys.argv[2]
want=[l.split("\t")[1].strip() for l in open(mf) if l.split("\t")[0]==cls]
cfg=json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))
srv=cfg["server"].rstrip("/"); tok=cfg["token"]
PAGE=500
rows={}; pages=[]; off=0
while True:
    url="%s/v1/data/query/production/task?limit=%d&offset=%d"%(srv,PAGE,off)
    req=urllib.request.Request(url,headers={"Authorization":"Bearer "+tok})
    docs=None
    for attempt in (1,2,3,4,5,6):
        try:
            docs=json.load(urllib.request.urlopen(req,timeout=90))["result"]["documents"]
            break
        except urllib.error.HTTPError as e:
            # guerrilla 500s intermittently under fleet load; the identical
            # request succeeds moments later. Retry the SAME request with
            # backoff, never a new shape.
            if e.code>=500 and attempt<6: time.sleep(6*attempt); continue
            raise
    if not isinstance(docs,list):
        print("WALK ABORT at offset %d: no result.documents list"%off); sys.exit(2)
    if len(docs)>PAGE:
        print("WALK ABORT at offset %d: page returned %d > limit %d"%(off,len(docs),PAGE)); sys.exit(2)
    pages.append(len(docs))
    for d in docs: rows[d["_id"]]=d
    if len(docs)<PAGE: break
    off+=PAGE
    if off>100000:
        print("WALK ABORT: walk did not terminate (offset past 100000)"); sys.exit(2)
print("WALK pages=%d loaded=%d unique=%d terminated=short-page(last=%d)"%(len(pages),sum(pages),len(rows),pages[-1]))
def s(v): return v.strip() if isinstance(v,str) else ""
ok=0; bad=[]
for i in want:
    r=rows.get(i)
    if not r: bad.append((i,"MISSING")); continue
    d=s(r.get("disposition")); rs=s(r.get("disposition_reason")); ow=s(r.get("disposition_owner")); tg=s(r.get("reopen_trigger"))
    prob=[]
    if d not in ("open","closed","parked"): prob.append("disposition=%r"%d)
    if not rs: prob.append("no reason")
    if d=="parked" and not tg: prob.append("no reopen_trigger")
    if d=="open" and (not ow or ow==i): prob.append("owner=%r"%ow)
    if prob: bad.append((i,"; ".join(prob)))
    else: ok+=1
print("class=%s pinned=%d COUNTED_OK=%d FAILING=%d"%(cls,len(want),ok,len(bad)))
for b in bad: print("  FAIL",b[0],b[1])
sys.exit(0 if not bad else 1)
