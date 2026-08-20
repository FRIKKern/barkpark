# Re-derivation recipe — cch wave 40 roster split, seal denominator, law-0 path line

Written by the wave-40 VERIFIER (v7-roster-and-law-zero), 2026-08-07. Nothing here is a
claim about the future; every line is a command that reproduces the number next to it.

## 0. The trap this run hit, first

A shared scratchpad path was CLOBBERED mid-run by a concurrent session writing a DIFFERENT
epic (`task-fb4fb869490b4213`, 147 children) over `scratchpad/epic.json` (485 children).
The second read of the "same" file returned the other epic's roster with no error. This is
the charter's documented stale-file misread hazard, live. **Always write roster reads to a
uniquely-named file and re-assert `.doc.doc_id` before counting.**

```
python3 -c "import json;d=json.load(open('<file>'));print(d['doc']['doc_id'],len(d['children']))"
```

## 1. Roster split (`bp task get` .children)

```
bp task get cloud-console-hardening-epic -o json > cch-roster-A.json
python3 - <<'PY'
import json,collections
c=json.load(open('cch-roster-A.json'))['children']
dr=[x for x in c if (x.get('doc_id') or '').startswith('drafts.')]
nd=[x for x in c if not (x.get('doc_id') or '').startswith('drafts.')]
print('all',len(c),dict(collections.Counter(x['lifecycle_status'] for x in c)))
print('drafts',len(dr),dict(collections.Counter(x['lifecycle_status'] for x in dr)))
print('published',len(nd),dict(collections.Counter(x['lifecycle_status'] for x in nd)))
PY
```

2026-08-07 04:47Z result: all 485 {done 256, open 177, cancelled 51, considering 1};
drafts 10 (ALL cancelled); published 475 {done 256, open 177, cancelled 41, considering 1}.

## 2. The seal predicate's own denominator

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic
```

Bare (no `--successor`) it REFUSES before evaluating any clause — exit 1,
`VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR`. With a successor:

```
roster: 475 children  {"open":177,"cancelled":41,"done":256,"considering":1}
CLAUSE (a) forwarding — residue 178 (live 177, considering 1)
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=175 considering=1 ...
```

**The two denominators AGREE.** 485 (.children) − 10 `drafts.*` = 475 = the predicate's
roster; residue 178 = 177 live + 1 considering. `LIVE_STATUSES` is `['open','in_progress']`
and `PENDING_STATUSES` is `['considering']` at `seal-predicate.mjs:113-114`; residue is
their union at `:357`. Charter D83's "considering is invisible to clause (a)" is STALE —
the predicate discloses it separately and counts it in residue.

## 3. Merge evidence per candidate close row

```
for n in 9917 9918 9920 9922 10007 10008 9848 9851; do
  gh pr view $n --json mergeCommit,state,title -q '[.state,.mergeCommit.oid,.title]|@tsv'
  gh pr view $n --json body -q .body | grep -o 'cch-w[0-9]*-[a-z0-9-]*' | sort -u
done
```

## 4. Unmet-criteria read (the field is `.doc.content.acceptance_criteria`, NOT `.doc.acceptance_criteria`)

```
bp task get <slug> -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)['doc']
print(d['criteria_progress'], json.dumps(d.get('claim'))[:120])
[print('UNMET',i,a['criterion'][:160]) for i,a in enumerate(d['content'].get('acceptance_criteria') or []) if not a.get('met')]"
```

`bp task get … -o json | jq .acceptance_criteria` returns nothing and reads as 0 criteria —
a silent zero, not an absence.

## 5. Law-0 path line for the census family

```
gh pr view 9920 --json files -q '.files[].path'   # -> cloud/priv/static/__binding_census.mjs
```

The binding census is NOT under `__preview__/`. Every app.js-subject census row queried
returns `parent_id=cloud-console-hardening-epic` (cch-w37-s4, cch-w37-bl-binding-census-drift-arm,
cch-w38-bl-census-positive-control-is-anchored-to-a-live-defect, cch-w39-s3). Note the rule
is by SUBJECT, not by files touched: #9922 edits four `__preview__/**` files and its row is
correctly parented here.
