# Re-derivation recipes — seal namespace lens + (b′) (W11 verify, 2026-07-28)

All rows measured 2026-07-28T01:52–01:58Z against `https://guerrilla.barkpark.cloud`,
repo `/Volumes/SATECHI/github/barkpark`, `origin/main` at `a9638ecef`.
Token from `~/.config/barkpark/config.json` (`.token`); every recipe below assumes:

```bash
export BP_TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
S=https://guerrilla.barkpark.cloud
```

Every count in this file is LIVE and CHURNS. The ready pool moved 815 → 814 inside
40 seconds during this session. Any port must re-derive, never quote.

## R1 — the query surface silently caps at 1000 and emits NO truncation flag

```bash
for L in 1000 1001 2000 5000; do printf "limit=$L -> "; \
  bp doc ls task --fields doc_id --limit $L -o json | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('count',d['count'],'limit_echo',d['limit'],'n_docs',len(d['documents']))"; done
```
All four print `count 1000 limit_echo 1000 n_docs 1000`. `count` is the PAGE size,
not the total — there is no `total`, no `has_more`, no truncation flag. The clamp is
`query_controller.ex:29` (`|> min(1000)`) and `tasks_controller.ex:248`
(`Params.parse_limit(params["limit"], 1000, 1000)`).

Consequence, measured: a single-call prefix lens
(`limit=1000` over `/v1/data/query/production/task`, filter `_id` startswith
`tgw|truth-grip`) returns **98** namespace rows. The paginated truth is **146**
(145 root-excluded). A 48-row silent under-count that exits 0.

**And it is green FOR THE WRONG REASON today, which is worse than being red.**
The claimable count is **34 under both lenses** — because open rows are recent and
happen to sort into the first page. So a naive single-call port would print the
correct (b) today and silently start lying the moment ordering or corpus size
shifts. Do not let a passing single-call lens be mistaken for a correct one:
```bash
curl -sG "$S/v1/data/query/production/task" --data-urlencode "limit=1000" \
  --data-urlencode "fields=_id,lifecycle_status" -H "Authorization: Bearer $BP_TOKEN" | python3 -c "
import sys,json
r=json.load(sys.stdin)['result']['documents']
p=[x for x in r if x['_id'].startswith(('tgw','truth-grip'))]
print('page',len(r),'prefix',len(p),'claimable',len([x for x in p if x['lifecycle_status'] in ('open','blocked')]))"
# page 1000 prefix 98 claimable 34     <- vs paginated: 3271 / 146 / 34
```

## R2 — the offset walk: stop on a short page, ASSERT the page count

```bash
mkdir -p /tmp/tgw11 && off=0; page=0; total=0
while :; do
  bp doc ls task --fields 'doc_id,parent_id,lifecycle_status' --limit 1000 --offset $off -o json \
    > /tmp/tgw11/q$page.json 2>/dev/null
  n=$(python3 -c "import json;print(len(json.load(open('/tmp/tgw11/q$page.json'))['documents']))")
  echo "page=$page off=$off n=$n"; total=$((total+n))
  [ "$n" -lt 1000 ] && break
  off=$((off+1000)); page=$((page+1))
done; echo "pages=$((page+1)) total=$total"
```
Expect 4 pages (`1000,1000,1000,271`), total 3271 task rows.

**HAZARD — offset pagination over a live corpus is NOT exact.** The same walk at
`--limit 500` (7 pages, 3271 rows) returned **3270 unique** ids: one row
(`gr-p5r9-seal-finishers-crit7-unstampable`) duplicated, two rows
(`mob-rt-s3-transcript-row-shape`, `mob-rt-s4-runtime-lane`) absent that the
1000-page walk saw, and one (`ae-search-eval-baseline-repair`) present that the
1000-page walk missed. Rows are created concurrently at the head of the ordering.
The tgw namespace is old and did NOT drift: both walks yield the identical
147/145/131 lens counts (verified by set-symmetric-difference = ∅). A port must
dedupe by `_id` and must not claim exactness for the whole corpus.

## R3 — the three lenses, root-excluded

```bash
python3 -c "
import json,glob
docs=[]
for f in sorted(glob.glob('/tmp/tgw11/q*.json')): docs+=json.load(open(f))['documents']
idx={}
for x in docs: idx.setdefault(x.get('parent_id'),[]).append(x['_id'])
seen=set(); q=['truth-grip-epic']
while q:
    n=q.pop()
    for c in idx.get(n,[]):
        if c not in seen: seen.add(c); q.append(c)
pref={x['_id'] for x in docs if x['_id'].startswith(('tgw','truth-grip'))}-{'truth-grip-epic'}
direct=set(idx.get('truth-grip-epic',[]))
print('closure',len(seen),'prefix',len(pref),'direct',len(direct),'UNION',len(seen|pref|direct))
print('prefix_misses',sorted(seen-pref))
print('direct_misses',sorted(seen-direct))
"
```
2026-07-28: closure **147**, prefix **145**, direct **131**, UNION **147**.

- The PREFIX lens misses exactly two rows, both hash-id children of the root:
  `task-a965c4fbfe3710f5` (done), `task-ae5358384170ec8b` (done).
- The DIRECT `filter[parent_id]` lens misses **16** rows — every child of
  `tgw1-workflow-gate-wiring` (itself `done`), which is D94's named orphan trap.
  One of the 16, `tgw2-verify-writes-back`, is `open` and IS in the live ready pool.
- CLOSURE ⊇ PREFIX and CLOSURE ⊇ DIRECT today, so UNION == CLOSURE. That is a
  measurement, not an invariant: a future `tgw*`-named row filed OUTSIDE the tree
  would break it. Compute the UNION.

## R4 — D94(b) and D94(b′) against the LIVE ready pool

```bash
bp task ready --all -o json 2>/dev/null > /tmp/tgw11-ready.json
python3 -c "
import json,glob
docs=[]
for f in sorted(glob.glob('/tmp/tgw11/q*.json')): docs+=json.load(open(f))['documents']
idx={}
for x in docs: idx.setdefault(x.get('parent_id'),[]).append(x['_id'])
seen=set(); q=['truth-grip-epic']
while q:
    n=q.pop()
    for c in idx.get(n,[]):
        if c not in seen: seen.add(c); q.append(c)
pref={x['_id'] for x in docs if x['_id'].startswith(('tgw','truth-grip'))}-{'truth-grip-epic'}
ns=seen|pref|set(idx.get('truth-grip-epic',[]))
ready={r['doc_id'] for r in json.load(open('/tmp/tgw11-ready.json'))['docs']}
print('pool',len(ready),'namespace',len(ns))
print(\"(b)  claimable namespace rows:\",len(ns&ready))
print(\"(b') root still claimable   :\",'truth-grip-epic' in ready)
"
```
2026-07-28: pool **815** (`--limit 2000`) / **814** (`--all`, 40s later),
namespace 147, **(b) = 33 claimable**, **(b′) = True — the root IS in the pool.**

Per-lens claimable count: closure 33, prefix 33, **direct 32**. The direct lens is
the one that under-reports, and the row it drops (`tgw2-verify-writes-back`) is
open. A retarget that keeps `fetchRoster(EPIC)` would print SEAL with a live
claimable row standing.

`bp task ready` also clamps at 1000 (`tasks_controller.ex:248`). The pool is 815
today so it is not truncating — but the port must assert `len(pool) < 1000` or
paginate, otherwise (b) silently reads a partial pool.

## R5 — `/v1/tasks` SILENTLY IGNORES `parent_id`; pin the QUERY surface by name

```bash
curl -sG "$S/v1/tasks" --data-urlencode "parent_id=truth-grip-epic" --data-urlencode "limit=1000" \
  -H "Authorization: Bearer $BP_TOKEN" | python3 -c "import sys,json;print('with parent_id ->',len(json.load(sys.stdin)['docs']))"
curl -sG "$S/v1/tasks" --data-urlencode "limit=1000" \
  -H "Authorization: Bearer $BP_TOKEN" | python3 -c "import sys,json;print('no  parent_id ->',len(json.load(sys.stdin)['docs']))"
curl -sG "$S/v1/data/query/production/task" --data-urlencode "filter[parent_id]=truth-grip-epic" --data-urlencode "limit=500" \
  -H "Authorization: Bearer $BP_TOKEN" | python3 -c "import sys,json;print('query filter[parent_id] ->',len(json.load(sys.stdin)['result']['documents']))"
```
Output: `1000` / `1000` / `131`.

Sharper form — add a parent that does not exist:
```bash
curl -sG "$S/v1/tasks" --data-urlencode "parent_id=NO-SUCH-PARENT-XYZ" --data-urlencode "limit=1000" \
  -H "Authorization: Bearer $BP_TOKEN" -o /tmp/c.raw
```
All three responses carry the **identical SET** of 1000 doc_ids (symmetric
difference 0, verified pairwise) and the identical first five ids. The ROOT
`truth-grip-epic` is itself returned by the "children of truth-grip-epic" query.
`parent_id` is accepted, dropped, and 200-OK'd — even when it names nothing.

Do NOT claim byte-identity: the ORDERED lists differ run to run (ties/churn at the
head of the ordering). The set equality is the proof; the ordering is noise.

**Pin `GET /v1/data/query/production/task` with `filter[parent_id]` by name.**
The charter's D108 note says the bare form "silently returns 500 unfiltered rows";
today it returns 1000 — same defect, the digit moved with the clamp.

## R6 — the prefix lens has no `_type` fence: it sweeps papers

```bash
for T in paper task; do printf "$T -> "; \
  curl -sG "$S/v1/data/query/production/$T" --data-urlencode "limit=1000" --data-urlencode "fields=_id" \
    -H "Authorization: Bearer $BP_TOKEN" | python3 -c "
import sys,json
r=json.load(sys.stdin)['result']['documents']
p=[x['_id'] for x in r if x['_id'].startswith(('tgw','truth-grip'))]
print('rows',len(r),'prefix_hits',len(p),p[:8])"; done
```
`paper -> rows 575 prefix_hits 4`:
`truth-grip-wave-11-2026-07-28`, `truth-grip-wave-10-2026-07-27`,
`truth-grip-wave-9-round-1-2026-07-27`, `truth-grip-seal-wave-9-2026-07-27`.

Swept all 39 schema types (`curl $S/api/schemas`): only `paper` (4) and `task`
carry the prefix. A type-less prefix lens would fold 4 wave PAPERS into the
namespace and, since papers have no `lifecycle_status`, silently classify them as
non-claimable — inflating the denominator and never the numerator. **Fence the
prefix lens with `_type == 'task'`.**

## R7 — the existing seal-predicate RUNS TODAY; root-exclusion is ACCIDENTAL

```bash
export BP_TOKEN=...   # as above
node cloud/priv/static/__preview__/seal-predicate.mjs; echo "EXIT=$?"
```
Exit **1**, 27 lines, ends `VERDICT: NO SEAL` / `4 live row(s) carry no forwarding
address and no gate label (clause a)`. It is a live, working base — the retarget is
a port, not a build.

Its lens is `fetchRoster(EPIC)` (`:119`, `filter[parent_id]` + `limit 500`), which
returns 82 for the cloud epic and 131 for truth-grip. Proof that its root-exclusion
is a side effect and not a check:
```bash
node -e '/* fetchRoster("truth-grip-epic") */' # see R5 curl; then:
# root in its own roster? false   <- because a parent_id census never returns the parent
```
D108's (b′) therefore CANNOT be inherited from this file. It must be written as an
explicit `pool.has(ROOT)` assertion, or clause (c) loses its only enforcement
silently.

Confirmed D111 correction: the `r.status !== 0` launder appears at **:171 AND
:176** (`git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs |
sed -n '171p;176p'`) — a port fixing one carries the other.

## R8 — the four target rows are OPEN and UNCLAIMED

```bash
for t in tgw9-s1-ledger-commons-honest tgw5-bl-level-mention-promotion \
         tgw9-s3-criteria-adjudicated tgw2-acceptance-suite; do
  bp task get $t -o json 2>/dev/null | python3 -c "
import sys,json;t=json.load(sys.stdin)['doc']
print(t['doc_id'],t['lifecycle_status'],t.get('assignee'),t.get('claim'))"; done
```
All four: `open None None`. No stale claim will bounce a builder.

The ROOT carries an EXPIRED claim (`epoch 2`, `expired_at
2026-07-27T16:39:01.705988Z`, `worker: null`, `previous_worker:
lead-wave10-land`) and is nonetheless in the ready pool — which is exactly why
(b′) must key on the POOL and not on `claim == null`.
