# cch wave 49 — false-open close sweep: re-derivation recipes (2026-08-07)

Baseline: `origin/main` @ `9af98373d`. Epic roster: 632 children / 309 open / 265 done / 57 cancelled / 1 considering.

## R1 — enumerate every partially-stamped cch-w4x row

```
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
python3 -c "
import json,re
d=json.load(open('/tmp/epic.json'))
rows=[c for c in d['children'] if re.match(r'cch-w4[0-9]',c['doc_id']) and c['lifecycle_status']=='open' and c.get('criteria_progress') and 0<c['criteria_progress']['met']<c['criteria_progress']['total']]
for c in sorted(rows,key=lambda x:x['doc_id']): print(c['doc_id'],c['criteria_progress'])
"
```
Expect 29 rows: 25 at N-1 (merge-gated clause only), 4 with a wider gap.

## R2 — read the UNMET criteria and the live claim

`bp task get <id> -o json` puts criteria at `.doc.content.acceptance_criteria` and the claim at
`.doc.claim` (`epoch`, `worker`, `expired_at`, `now.text`). `worker: null` + `expired_at` in the past
== lapsed. Every one of the 29 is lapsed as of 2026-08-07T18:13Z.

```
bp task get <id> -o json | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['doc']
print(d['doc_id'],d['criteria_progress'],(d.get('claim') or {}).get('epoch'),(d.get('claim') or {}).get('worker'))
for i,c in enumerate(d['content']['acceptance_criteria'],1):
    if not c.get('met'): print(i, re.sub(r'\s+',' ',str(c['criterion']))[:300])
"
```

## R3 — row -> PR, when the commit message does not carry the slug

Only 13/29 slugs appear in a squash commit message. The reliable key is the branch named in
`.doc.claim.now.text` (`loop-epic/…`), often with a reviewer `-r` suffix:

```
gh pr list --repo FRIKKern/barkpark --state all --head "loop-epic/<branch>" \
  --json number,state,mergeCommit,mergedAt
# if empty, retry with the branch name + "-r"
```

## R4 — per-head gate verdict (NOT `gh run list`)

`gh run list` rolls advisory failures up as success. Read the PR head's own rollup:

```
gh pr view <pr> --repo FRIKKern/barkpark --json state,mergeable,statusCheckRollup \
  -q '"state=\(.state) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]?|"\(.name)=\(.conclusion)"]|join(" "))"'
```

The instrument was proved losable, not assumed: #10154 returns `Console gate=FAILURE`
(`Overflow guard (rendered)=FAILURE`) and #10155 returns `Console gate=FAILURE Cloud gate=FAILURE`
(`Cloud path-escape ratchet=FAILURE`, `Console path-escape ratchet=FAILURE`) — while all 25 merged
heads return `Cloud gate=SUCCESS Security gate=SUCCESS Console gate=SUCCESS Elixir gate=SUCCESS`.

Caveat: a merged PR's rollup returns ~10 entries where an open PR's returns ~35 — the leaf jobs are
not retrievable post-merge. Only the four aggregate gates are provable retroactively.

## R5 — the four rows that are NOT falsely open

```
gh pr list --repo FRIKKern/barkpark --state open --limit 60 --json number,title,mergeable
```
- `cch-w40-s3` -> #10085 OPEN CONFLICTING
- `cch-w40-s4` -> #10086 OPEN CONFLICTING
- `cch-w42-s2` -> #10154 OPEN MERGEABLE, Console gate FAILURE
- `cch-w42-s4` -> #10155 OPEN MERGEABLE, Console + Cloud gate FAILURE

## R6 — the census path check (the "unevaluable criteria" premise)

```
git ls-tree -r --name-only origin/main | grep -i census
git cat-file -e origin/main:cloud/priv/static/__binding_census.mjs && echo EXISTS
git cat-file -e origin/main:cloud/priv/static/__preview__/__binding_census.mjs || echo ABSENT
```
No row in the epic cites `cloud/priv/static/__preview__/__binding_census.mjs`. `cch-w46-s5` #7 and
`cch-w46-s6` #7 cite bare `__binding_census.mjs`, which resolves to the path that EXISTS.

## R7 — closing a lapsed row without a 409

Every claim is lapsed and `worker` is null, so `close` on the stale epoch is the only path that can
raise `doc_changed_since_claim`. Re-claim first (fresh epoch + fresh `work_field_digests` taken from
current content), then `bp task close <id> <worker> <new-epoch>` in the same breath.
