#!/usr/bin/env python3
"""Row-level re-derivation of the PDS closure. Same transport discipline as
scripts/pds-ledger-census.sh (explicit offsets, status-first, shape-asserted),
but emits EVERY row with the fields the round mutates."""
import hashlib, json, os, sys, time, urllib.request, urllib.error
from collections import defaultdict
from datetime import datetime, timezone

ROOT = "task-2ac1f95237c4a8e5"
TERMINAL = ("done", "cancelled", "canceled")
LIMIT = 1000

cfg = json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))
server = os.environ.get("BARKPARK_SERVER") or cfg.get("server")
token = os.environ.get("BARKPARK_TOKEN") or cfg.get("token")
server = server.rstrip("/")

def get(path, query):
    req = urllib.request.Request("%s%s?%s" % (server, path, query), headers={
        "Authorization": "Bearer %s" % token, "Accept": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(1.0 * (2 ** attempt) + 0.5); continue
            return e.code, e.read()
    raise SystemExit("429 exhausted")

started = datetime.now(timezone.utc)
corpus = {}
pages = []
offset = 0
while True:
    st, body = get("/v1/data/query/production/task", "limit=%d&offset=%d" % (LIMIT, offset))
    assert st == 200, (st, body[:300])
    res = json.loads(body)["result"]
    assert res["limit"] == LIMIT and res["offset"] == offset, res
    docs = res["documents"]
    assert res["count"] == len(docs)
    pages.append(len(docs))
    for d in docs:
        corpus[d["_id"]] = d
    if len(docs) < LIMIT:
        break
    offset += LIMIT
    time.sleep(0.15)
finished = datetime.now(timezone.utc)

kids = defaultdict(list)
for i, d in corpus.items():
    p = d.get("parent_id")
    if p:
        kids[p].append(i)
closure, seen, frontier = [], set(), [(c, 1) for c in sorted(kids.get(ROOT, []))]
depth = {}
while frontier:
    n, dp = frontier.pop(0)
    if n in seen: continue
    seen.add(n); closure.append(n); depth[n] = dp
    for c in sorted(kids.get(n, [])):
        if c not in seen: frontier.append((c, dp + 1))
escaped = [i for i, d in corpus.items() if d.get("parent_id") in seen and i not in seen]
assert not escaped, escaped[:5]

def md5(s):
    return hashlib.md5(" ".join((s or "").split()).encode()).hexdigest()[:8] if (s or "").strip() else ""

rows = []
for i in sorted(closure):
    d = corpus[i]
    ls = d.get("lifecycle_status") or ""
    reason = d.get("disposition_reason") or ""
    trig = d.get("reopen_trigger") or ""
    rows.append({
        "id": i,
        "live": ls not in TERMINAL,
        "lifecycle_status": ls,
        "disposition": d.get("disposition") or "",
        "reason_md5": md5(reason),
        "reason_len": len(reason),
        "disposition_owner": d.get("disposition_owner") or "",
        "reopen_trigger": trig,
        "updatedAt": d.get("_updatedAt") or "",
        "rev": d.get("_rev") or "",
        "parent_id": d.get("parent_id") or "",
        "depth": depth[i],
        "title": (d.get("title") or "")[:80],
    })

out = {
    "started": started.isoformat().replace("+00:00", "Z"),
    "finished": finished.isoformat().replace("+00:00", "Z"),
    "corpus_size": len(corpus),
    "pages": pages,
    "closure_size": len(closure),
    "live": sum(1 for r in rows if r["live"]),
    "rows": rows,
}
json.dump(out, open(sys.argv[1], "w"), indent=1, sort_keys=True)
print("closure=%d live=%d corpus=%d window=%s->%s" % (
    len(closure), out["live"], len(corpus), out["started"], out["finished"]))
