# Wave 62 — Standing Law 0 re-derivation recipe (2026-08-09)

Three numbers, three instruments, three different answers. Quote the one you name.

## 1. The seal predicate CANNOT produce a Law-0 number today

```
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs > /tmp/seal-origin.mjs
node /tmp/seal-origin.mjs --successor cch-instruments-epic --repo /Volumes/SATECHI/github/barkpark
```
→ `VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN code=ROSTER-TRUNCATED`

The refusal is correct: `fetchRoster` reads one page at `limit=500` and the epic has 815
published children. Known and filed as `cch-w44-bl-init-wiring-is-unpinned` (whose TITLE
describes a different defect than its BODY — classify by body, D172).

DANGER, reproduced live 2026-08-09: the primary checkout's copy is 1009 lines behind
origin/main and prints a CONFIDENT WRONG verdict instead of refusing:

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic
```
→ `roster: 500 children {"open":333,...}` … `VERDICT-TOKEN: … NO-SEAL a=FAIL b=FAIL c=PASS orphans=335`

335 is a page-limit artifact. Never quote it.

## 2. The published denominator (use THIS one)

```
curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
  --data-urlencode 'limit=1000' -H "Authorization: Bearer $BP_TOKEN" \
| python3 -c "import sys,json,collections;r=json.load(sys.stdin)['result'];print(len(r['documents']),collections.Counter(x['lifecycle_status'] for x in r['documents']))"
```
2026-08-09T14:47Z → `815 Counter({'open': 404, 'done': 344, 'cancelled': 64, 'in_progress': 2, 'considering': 1})`

Server caps `limit` at 1000 and `result.count` is the PAGE length, not a total —
`limit=500` returns `count=500`, `limit=2000` returns `count=815, limit=1000`. A full
page is indistinguishable from a complete one without asking for more than you expect.

## 3. `bp task get` (drafts-inflated — the charter forbids quoting it)

```
bp task get cloud-console-hardening-epic -o json > /tmp/e.json
python3 -c "import json,collections;d=json.load(open('/tmp/e.json'));print(len(d['children']),collections.Counter(c['lifecycle_status'] for c in d['children']))"
```
→ `839 Counter({'open': 414, 'done': 344, 'cancelled': 78, 'in_progress': 2, 'considering': 1})`

839 − 815 = 24 `drafts.*` rows exactly (10 open, 14 cancelled). Cancelling a draft twin
pays against 414 and NOT against 404.

## 4. Draft twins

```
python3 -c "import json;d=json.load(open('/tmp/e.json'));ids={c['doc_id'] for c in d['children']};b={c['doc_id']:c for c in d['children']}
[print(b[i]['lifecycle_status'], i, 'TWIN=' + (b[i[7:]]['lifecycle_status'] if i[7:] in ids else 'NONE')) for i in sorted(ids) if i.startswith('drafts.')]"
```
10 open drafts: 3 `zz-p-*` probes (title `probe`, empty description, 0 criteria, NO twin,
created 2026-08-08T11:30Z) and 7 named rows, all with a twin.

## 5. Merge-gated arrears

```
gh pr list --search '"<slug>" in:body' --state all --json number,state,mergeCommit,mergedAt
gh api repos/:owner/:repo/compare/<mergeSha>...main --jq .status   # "ahead" == ancestor of main
```
