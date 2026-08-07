# Re-derivation recipe — deploy-reliability wave 5 ledger hygiene (drafts.* phantoms, the space dup, the unpublished goal)

Sampled 2026-08-06 ~17:00–17:15Z against `guerrilla.barkpark.cloud` via `bp`.
Every number below drifts; re-derive, never quote.

## 1. The epic roster and its draft phantoms

```
bp task get task-fb4fb869490b4213 -o json > /tmp/dr-epic.json
python3 - <<'PY'
import json
from collections import Counter
d=json.load(open('/tmp/dr-epic.json')); ch=d['children']
print(d['doc']['title'][:80]); print('n',len(ch),Counter(c['lifecycle_status'] for c in ch))
by={}
for c in ch:
    k=c['doc_id'][7:] if c['doc_id'].startswith('drafts.') else c['doc_id']
    by.setdefault(k,[]).append(c['doc_id'])
print('TWIN PAIRS:',[k for k,v in by.items() if len(v)>1])
print('ORPHAN DRAFTS:',[c['doc_id'] for c in ch if c['doc_id'].startswith('drafts.') and len(by[c['doc_id'][7:]])==1])
PY
```

Observed: 88 children, `{'open': 78, 'done': 10}`, **zero `in_progress`**.
11 `drafts.*` rows: 9 exact-slug twins + 2 orphans
(`drafts.task-aa775c3d30287a4b`, `drafts.dr-w3-s2-9727-dead-describer-clauses`).
Honest denominator: **67 open + 10 done = 77**, never 78/88.

## 2. Proof the twins are separate DOCUMENTS, not draft revisions

```
for t in dr-w4-s4-fleet-list-carries-pressure drafts.dr-w4-s4-fleet-list-carries-pressure; do
  bp task get "$t" -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['id'],d['status'],d['lifecycle_status'],d.get('criteria_progress'))"
done
```

Observed distinct UUIDs (`68c44be7-…` published/done 8/8 vs `18f8b78c-…` draft/open 0/8).
Distinct ids ⇒ genuine phantom rows, not the published doc's own draft edit.

## 3. Proof the phantoms are CLAIMABLE (the actual hazard)

```
bp task ready --all -o json | python3 -c "
import sys,json;s=sys.stdin.read();d=json.loads(s[s.index('{\"docs\"'):])
print(len(d['docs']),'ready;',len([x for x in d['docs'] if x['doc_id'].startswith('drafts.')]),'drafts')"
```

Observed 1952 ready, 65 of them `drafts.*` — including
`drafts.task-aa775c3d30287a4b` and `drafts.dr-w3-s2-9727-dead-describer-clauses`.
Root cause already filed: `api/lib/barkpark/tasks/queue.ex:105-110` has no publication
predicate (see `pds-w29-bl-drafts-in-ready-handoff`, `tgw10-bl-drafts-in-ready-pool`).

## 4. The duplicate space rows

```
for t in task-3b69c3e24bf3d8ca task-ca88b8ea571b3470; do
  bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['status'],d['lifecycle_status'],d['inserted_at']);print(' ',d['title'][:110])"
done
bp search query "agent space route 404 v1/agent/space"
```

Both published, both `open`, both parented to the epic, both own POST `/v1/agent/space`
plus the `AgentEvent @types` widening. `3b69c3e24bf3d8ca` 13:12:54Z (richer brief, adds the
render surface + D58 separation). `ca88b8ea571b3470` 14:29:32Z (adds one arm the older lacks:
the agent must BACK OFF from a route it has proved absent, not 404 96×/day).

## 5. Merge state of the stale-open N-1/N rows

```
for s in dr-w1-s1-graph-visibility-bound-readmit dr-w1-s2-fleet-ledger-classifier \
  dr-w1-s3-409-deferral-index-rekey dr-w1-s4-webhook-doctype-filter \
  dr-w1-s5-swallow-records-upstream-status dr-w2-s1-recorder-build-id-keyed-log \
  dr-w2-s2-provision-rmrf-wedge dr-w2-s3-poll-grace-5xx-and-named-refusal \
  dr-w2-s4-scrub-knows-our-own-token dr-w2-s5-cli-status-stops-lying \
  dr-w2-s6-engine-one-extractor-health-slow-vs-broken \
  dr-w2-s7-scoped-search-permission-clamp dr-w3-s5-door-refuses-box-at-capacity \
  dr-terminal-record-prune-tie-order; do
  printf '%-52s ' "$s"
  gh pr list --state all --search "$s" --json number,state,mergedAt --limit 3
done
```

Observed: 13 of 14 have a MERGED PR (#9613–#9617, #9727, #9729–#9734);
only `dr-w3-s5-door-refuses-box-at-capacity` (#9827) is still OPEN.

## 6. The governing prior ruling (lives in ANOTHER charter)

```
bp task get cch-w30-bl-discard-three-stranded-draft-twins -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['content']['description'])"
grep -n -i "drafts\.\|discard-draft" .claude/workflows/bp-deploy-reliability-charter.md
```

cloud-console-hardening **D105** ("count `drafts.*` as duplicates, never as rows") and
**D190** ("CANCELLED via `bp doc discard-draft`, never closed") are the ruling.
The deploy-reliability charter has ZERO occurrences — the ruling is unimported here.
