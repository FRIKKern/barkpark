# Re-derivation recipes — wave 65 fabrication audit + handle resolution (2026-08-09)

## R1 — Resolve a `cch-w<NN>-s<N>` handle to its real doc_id

`bp task get <handle>` 404s: the handle is a PREFIX, the doc_id is the full slug.
`bp search query "<handle>"` does NOT return it either (FTS indexes content, not slug prefixes).
The only reliable resolution is the full task dump:

```sh
bp task ls --all -o json > /tmp/tasks.json
python3 -c "
import json,sys
d=json.load(open('/tmp/tasks.json'))['docs']
h=sys.argv[1]
print([x['doc_id'] for x in d if x['doc_id'].startswith(h+'-')])
" cch-w64-s6
```

Note the dump's shape: top-level key is `docs`; the slug lives in `doc_id`
(`id` is a UUID). Criteria live under `content.acceptance_criteria`.

## R2 — Read back every acceptance criterion of a closed row

```sh
bp task get <full-doc-id> -o json | python3 -c "
import json,sys
t=json.load(sys.stdin)['doc']['content']
for i,c in enumerate(t.get('acceptance_criteria',[])):
    print(i, c.get('met'), str(c.get('evidence'))[:200])
"
```

## R3 — Fabrication test on a merge-gated criterion

For each cited PR, confirm state + merge sha, then confirm the sha is an ancestor of main:

```sh
gh pr view <PR> --json number,state,mergedAt,mergeCommit \
  --jq '[.state,(.mergedAt//"-"),(.mergeCommit.oid[0:12]//"-")]|@tsv'
gh api repos/:owner/:repo/compare/<merge-sha>...main --jq .status   # expect: ahead
```

Head-sha gate proof (the default 30-row page OMITS required contexts on busy heads —
always `per_page=100`):

```sh
gh api "repos/:owner/:repo/commits/<head-sha>/check-runs?per_page=100" \
  --jq '[.total_count, ([.check_runs[]|select(.name|test("Cloud gate|Console gate|Elixir gate|PR references an active task"))|.name+"="+.conclusion]|join(", "))]|@tsv'
```

## R4 — The honest-miss test (D781)

A criterion that demands TWO facts in a merged PR body, where only one is present,
must stay `met:false` with the miss named. Re-derive the miss itself:

```sh
gh pr view 10727 --json body --jq .body | grep -inE 'ACTION_LABELS|raw slug|D582'   # rc=1 = the miss
gh pr view 10727 --json body --jq .body | sed -n '26p'                              # the fact that IS present
```

## R5 — Spot-check a non-PR evidence string against origin/main

Evidence naming a file:line is re-derivable; evidence naming a suite COUNT is a
historical snapshot and will drift as the suite grows. Only the former is a
fabrication test.

```sh
git fetch -q origin main
git show origin/main:cloud/priv/static/__preview__/breakpoint-sweep.test.mjs | sed -n '594,604p'
git show origin/main:cloud/test/barkpark_cloud/registry_update_status_test.exs | sed -n '158,170p'
git grep -n "PIN_TOTAL_SCENARIOS" origin/main -- cloud   # lives in member-authority-sweep.mjs, NOT smoke.mjs
```
