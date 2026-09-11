#!/usr/bin/env python3
"""Row-level re-derivation of the PDS closure. Same transport discipline as
scripts/pds-ledger-census.sh (explicit offsets, status-first, shape-asserted),
but emits EVERY row with the fields the round mutates.

THE WALK IS NOT LOCAL. It used to page with `assert st == 200`,
`assert res["limit"] == LIMIT and res["offset"] == offset`,
`assert res["count"] == len(docs)`, and `if len(docs) < LIMIT: break`. Two things
were wrong with that. (a) EVERY one of those guards is a no-op under
`python3 -O`, and the shape guards are the ones that catch a SILENT under-read --
a server that caps the page or disagrees with its own count then goes unnoticed
and the closure comes back smaller with exit 0. (b) Even with asserts live, a
500'd page (observed 2026-07-30 ~19:22Z under concurrent write load) died as a
bare AssertionError or a KeyError on `["result"]`: loud, but unnamed, and one
`except Exception` away from becoming an empty page and then the END OF THE
BOARD. The terminator now lives in census_walk.walk_pages, which refuses with a
name and never breaks, and it terminates on the server's EXACT `hasMore` rather
than on page length. Selftest: python3 census_walk.py --selftest."""
import hashlib, json, os, sys, time, urllib.request, urllib.error
from collections import defaultdict
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from census_walk import walk_pages, CensusWalkRefusal  # noqa: E402

ROOT = "task-2ac1f95237c4a8e5"
TERMINAL = ("done", "cancelled", "canceled")
LIMIT = 1000

cfg = json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))
server = os.environ.get("BARKPARK_SERVER") or cfg.get("server")
token = os.environ.get("BARKPARK_TOKEN") or cfg.get("token")
server = server.rstrip("/")

def fetch(offset):
    """(status, body) for one page. A 429 is retried -- the SAME request, never a
    new shape -- and an exhausted retry budget hands the status back UNCHANGED so
    walk_pages can name it. A failed read is never converted into an empty page
    here; that conversion IS the defect this file was rewritten to remove."""
    url = "%s/v1/data/query/production/task?limit=%d&offset=%d" % (server, LIMIT, offset)
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer %s" % token, "Accept": "application/json"})
    last = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            last = (e.code, e.read())
            if e.code == 429 and attempt < 4:
                time.sleep(1.0 * (2 ** attempt) + 0.5)
                continue
            return last
        except urllib.error.URLError as e:
            last = (599, str(e.reason).encode())
            if attempt < 4:
                time.sleep(1.0 * (2 ** attempt) + 0.5)
                continue
            return last
    return last if last else (599, b"retries exhausted with no response")

started = datetime.now(timezone.utc)
try:
    walk = walk_pages(fetch, LIMIT, on_page=lambda off, n, more: time.sleep(0.15))
except CensusWalkRefusal as exc:
    raise SystemExit("pds-w25-rowdump: %s\nno closure was derived -- there is no dump."
                     % exc)
corpus = walk.rows
pages = walk.pages
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
    "walk_terminator": walk.terminator,
    "closure_size": len(closure),
    "live": sum(1 for r in rows if r["live"]),
    "rows": rows,
}
json.dump(out, open(sys.argv[1], "w"), indent=1, sort_keys=True)
print("closure=%d live=%d corpus=%d terminated=%s window=%s->%s" % (
    len(closure), out["live"], len(corpus), walk.terminator,
    out["started"], out["finished"]))
