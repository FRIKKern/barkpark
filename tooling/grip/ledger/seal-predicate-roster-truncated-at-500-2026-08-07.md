# Re-derivation recipe — the seal predicate's roster truncates at 500, and the on-disk copy lies

Filed by wave 43's law-0 arrears verifier, 2026-08-07. Task: `task-35e4fa473743f866`
(parent `cch-instruments-epic`).

## 1. origin/main's predicate REFUSES (exit 2, ROSTER-TRUNCATED)

```sh
cd /Volumes/SATECHI/github/barkpark
git fetch origin --quiet
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs > /tmp/seal-origin.mjs
node /tmp/seal-origin.mjs --successor cch-instruments-epic --repo /Volumes/SATECHI/github/barkpark
echo "EXIT=$?"
```

Expected (2026-08-07):

```
INFRA FAULT ...: the roster of cloud-console-hardening-epic came back FULL — 500 rows
against a page limit of 500, and this endpoint returns no total and no hasMore.
VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN
  epic=cloud-console-hardening-epic code=ROSTER-TRUNCATED repo=/Volumes/SATECHI/github/barkpark
EXIT=2
```

**Do NOT pipe this to `tail` inside an `&&` chain** — the pipe eats the exit code
(rotating-charter-slot trap). Redirect to a file, then `echo "EXIT=$?"`.

## 2. The stale primary-checkout copy prints a CONFIDENT WRONG verdict

```sh
cd /Volumes/SATECHI/github/barkpark
git rev-parse HEAD origin/main            # HEAD 0789ab90a5 was BEHIND origin/main dad66869e
git diff --stat origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs
node cloud/priv/static/__preview__/seal-predicate.mjs \
  --successor cch-instruments-epic --repo /Volumes/SATECHI/github/barkpark > /tmp/seal-local.out
echo "EXIT=$?"; tail -6 /tmp/seal-local.out
```

Expected: `1153 +++----` (144 insertions / 1009 deletions vs origin/main), `EXIT=1`, and

```
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=218 ...
```

`orphans=218` is measured over a population silently truncated at 500. An agent reading
the instrument from disk gets a determinate number where the current instrument refuses.

## 3. The live denominator (the number law 0 requires)

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "\
import json,sys,collections;d=json.load(sys.stdin);\
p=[c for c in d['children'] if not c['doc_id'].startswith('drafts.')];\
print(len(d['children']),len(p),collections.Counter(c['lifecycle_status'] for c in p))"
```

2026-08-07: `543 530 Counter({'done': 257, 'open': 226, 'cancelled': 42, 'in_progress': 4,
'considering': 1})` → **LIVE = 230** (open + in_progress). Wave 42 opened at 213 → **+17**.

Charter D105: `drafts.*` are duplicates, never rows. `child_count` (543) is a LIFETIME total.

## 4. Rows one merge-gate criterion from done, derived not quoted

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "\
import json,sys;d=json.load(sys.stdin)
for c in d['children']:
    if c['doc_id'].startswith('drafts.'): continue
    if c['lifecycle_status'] not in ('open','in_progress'): continue
    cp=c.get('criteria_progress') or {}
    if cp.get('total') and cp['total']-cp['met']==1: print(c['doc_id'],cp,c['lifecycle_status'])"
```

Then, per row, confirm the PR really merged (never trust the slug-in-body heuristic — see
amendment 3 on `cch-w42-bl-twelve-paid-rows-await-the-lead-stamp`):

```sh
gh pr list --repo FRIKKern/barkpark --search '"<row-slug>" in:body' --state all \
  --json number,state,mergeCommit,title --limit 5
```

2026-08-07 result: 20 rows are one criterion from done; of the non-arrears ones only
`cch-w42-s5-notification-event-vocabulary-census` has a MERGED PR (#10156 `dad66869e`) —
the thirteenth repayable row, invisible to the twelve's census because it merged after it
was written. `cch-w38-s2` (#9956), `cch-w39-s1` (#10005), `cch-w39-s2` (#10006),
`cch-w40-s3` (#10085) and `cch-w40-s4` (#10086) are all still **OPEN PRs** — not arrears.
