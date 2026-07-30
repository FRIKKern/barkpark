import json,os,sys,urllib.request
cls=sys.argv[1]
mf=sys.argv[2]
want=[l.split("\t")[1].strip() for l in open(mf) if l.split("\t")[0]==cls]
cfg=json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))
srv=cfg["server"].rstrip("/"); tok=cfg["token"]
rows={}
for off in range(0,5000,1000):
    req=urllib.request.Request("%s/v1/data/query/production/task?limit=1000&offset=%d"%(srv,off),headers={"Authorization":"Bearer "+tok})
    docs=json.load(urllib.request.urlopen(req,timeout=90))["result"]["documents"]
    for d in docs: rows[d["_id"]]=d
    if len(docs)<1000: break
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
for b in bad[:15]: print("  FAIL",b[0],b[1])
sys.exit(0 if not bad else 1)
