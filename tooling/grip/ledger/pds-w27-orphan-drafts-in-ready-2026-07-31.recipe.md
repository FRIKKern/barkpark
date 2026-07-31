# Re-derivation recipe — orphan drafts served as ready work (PDS wave 27 verify)

Measured 2026-07-31 against live guerrilla (`https://guerrilla.barkpark.cloud`, dataset `production`).
Every number below is re-derived by the command directly above it. Nothing is quoted from a prior wave.

## 1. The 28 orphan drafts in the ready pool

```bash
cd /Volumes/SATECHI/github/barkpark
bp task ready --all -o json > /tmp/rdy.json
for o in 0 1000 2000 3000; do bp doc query task --fields doc_id --limit 1000 --offset $o -o json > /tmp/q$o.json; done
python3 -c "import json;pub=set();[pub.update(x['_id'] for x in json.load(open('/tmp/q%d.json'%o))['documents']) for o in (0,1000,2000,3000)];r=[x['doc_id'] for x in json.load(open('/tmp/rdy.json'))['docs']];dr=[i for i in r if i.startswith('drafts.')];print('ready',len(r));print('drafts in ready',len(dr));print('with published twin',sum(1 for i in dr if i[7:] in pub))"
```

Observed 2026-07-31: `ready 1262` · `drafts in ready 28` · `with published twin 0`.
All 28 carry `status: "draft"` in the brief render; 26 omit `lifecycle_status` (i.e. `open`), 2 are
`blocked` (`drafts.paper-editor-parity-wave3`, `drafts.task-bb2835e35434dd8f`).
Zero rows in the whole 1262 carry a `disposition` key.

## 2. The census cannot see them (perspective default = published)

```bash
T=<bp token>
for p in published raw drafts; do
  curl -s -H "Authorization: Bearer $T" \
    "https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=1000&offset=0&perspective=$p" \
  | python3 -c "import sys,json;d=json.load(sys.stdin)['result'];print('$p', len(d['documents']), sum(1 for x in d['documents'] if x['_id'].startswith('drafts.')))"
done
```

Observed: `published 1000 0` · `raw 1000 222` · `drafts 1000 222`.
Full paging: **published 3902 · raw 4238 · draft rows 336 · orphan drafts (no published twin) 316**.
`scripts/pds-ledger-census.sh` builds its path at line 388 as
`/v1/data/query/%s/%s` and never sends `perspective`, so its corpus is the 3902 — the 336 are
outside its denominator by construction.

## 3. The admitting clause in the ready query

`git show origin/main:api/lib/barkpark/tasks/queue.ex`

- Candidate filter, lines **106-109**: `type == "task"`, `content->>'kind' == "task"`,
  `lifecycle_status in @ready_lifecycle_statuses`, `QueueGate.executable_query()`.
  **No publication predicate.** `Barkpark.Content` (moduledoc lines 17-20) defines the
  `:published` / `:drafts` / `:raw` perspectives and states the default is `:raw` (line 59);
  `Queue` never touches that seam.
- Axis 3, lines **152-168**: `not exists(o where o.doc_id == regexp_replace(d.doc_id,'^drafts\.','')
  and o.doc_id != d.doc_id and same scope)`. This is a **conditional suppression**, not a filter:
  it fires only when a distinct published twin exists. For a draft with no twin the subquery is
  empty, `NOT EXISTS` is TRUE, and the draft is admitted.

**Therefore: the omission is that lines 106-109 carry no `doc_id NOT LIKE 'drafts.%'`
(or perspective) predicate, and axis 3 by design cannot substitute for one.**

## 4. tgw10 criterion 4 — the duplicate doc_id is still live

```bash
bp task ls --all -o json | python3 -c "import sys,json,collections;rows=json.load(sys.stdin)['docs'];c=collections.Counter(x['doc_id'] for x in rows);print(len(rows),{k:v for k,v in c.items() if v>1})"
```

Observed: `4240 {'drafts.stw1-basepath-redirect-fix': 2}` — UUIDs
`3b0d293a-acb9-40d8-9326-3e948b17ab36` and `c6cb6318-3dff-4257-82b3-a9786d7b0190`,
both `status: draft`, both `lifecycle_status: cancelled` (hence NOT in the ready pool).

## 5. The help text under audit

`bp task ready --help` → "List executable, unblocked tasks (priority order by default)." — no
`--view` flag exists. `internal/cli/mcp_tasks.go:117` describes the same queue to agents as
"work available to claim."
