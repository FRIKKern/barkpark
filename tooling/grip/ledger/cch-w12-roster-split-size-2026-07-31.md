# Recipe — cloud-console-hardening-epic roster split size, by BODY (2026-07-31)

Re-derives the wave-12 ruling's load-bearing number: how many of the epic's live rows
name a divergence a person can see on a console surface, and how many name a defect in
an instrument (gate / generator / harness / spec / ledger / preview shim / CI / docs).

Measured 2026-07-31T04:5xZ: **189 children — 91 open, 81 done, 16 cancelled, 1 considering
= 92 raw live.** Split by body: **14 console-facing, 5 operator/human-gate-blocked, 73
instrument-class (79.3%).**

TWO DENOMINATORS, ONE ROSTER. Three of the 91 open rows are `drafts.*` entries
(`drafts.gr-backlog-css-brace-detector`, `drafts.cch-bl-floor-blind-to-readme-and-uncalled`,
`drafts.cch-w11-s1-flip-behind-a-generator-that-cannot-lose`). `seal-predicate.mjs` excludes
them (charter D124), so 91 − 3 = **88 live + 1 considering = 89** is the predicate's count and
the lead's; **92** is the raw child count with drafts included. They are not two measurements.
Instrument-class net of drafts is **70**; the split is 14 / 5 / 70 = 89.

## Step 1 — the roster (never `GET /v1/tasks?filter[parent_id]=`; see cch-finding-roster-tooling-contract)

    bp task get cloud-console-hardening-epic -o json > epic.json
    python3 - <<'PY'
    import json, collections
    d = json.load(open('epic.json'))
    ch = d['children']
    print(collections.Counter(x['lifecycle_status'] for x in ch))
    live = [x for x in ch if x['lifecycle_status'] not in ('done', 'cancelled')]
    print('live', len(live))
    open('live_ids.txt', 'w').write('\n'.join(x['doc_id'] for x in live) + '\n')
    PY

`.children` carries only a summary (doc_id / title / lifecycle_status / criteria_progress).
It does NOT carry the body — a title-only classification is not this measurement.

## Step 2 — the bodies (one read per row; the summary is not evidence)

    mkdir -p bodies
    while read id; do bp task get "$id" -o json > "bodies/$id.json"; done < live_ids.txt
    ls bodies | wc -l   # must equal the live count

TRAP: `live_ids.txt` written without a trailing newline loses its LAST row to `while read`.
Verify the file count against the live count before classifying.

## Step 3 — classify on `content.description` + `content.acceptance_criteria`

Predicate: **a row is console-facing iff its divergence is observable by a signed-in (or
pre-auth) person on a console surface they can reach** — a rendered screen, a computed
style, or an HTTP response their browser receives. A row is instrument-class iff its
subject is a gate, generator, harness, oracle, preview shim, workflow, spec, doc, charter
census, or the task ledger itself.

    python3 - <<'PY'
    import json, glob
    for f in sorted(glob.glob('bodies/*.json')):
        d = json.load(open(f))['doc']
        c = d.get('content') or {}
        print('=' * 90)
        print(d['doc_id'], d['lifecycle_status'], d['inserted_at'][:10])
        print(d['title'])
        print((c.get('description') or '')[:900])
        for a in c.get('acceptance_criteria') or []:
            print('  [%s] %s' % ('x' if a.get('met') else ' ', a.get('criterion', '')[:200]))
    PY

## Step 4 — live-claim check before any `bp task move`

    python3 - <<'PY'
    import json, glob
    for f in sorted(glob.glob('bodies/*.json')):
        d = json.load(open(f))['doc']
        if d.get('claim') or d.get('assignee'):
            print(d['doc_id'], d.get('lifecycle_status'), d.get('assignee'),
                  (d['claim'] or {}).get('epoch'), (d['claim'] or {}).get('expired_at'))
    PY

At 2026-07-31T04:54Z: 10 rows carry claim residue, **all expired or released** (latest
`expired_at` 2026-07-31T03:33:00Z), and ZERO rows are `lifecycle_status: in_progress`.

## Step 5 — free closes, proven against origin/main (not the worktree)

    git show origin/main:api/mix.lock | grep '"req"'                       # 0.6.3
    git show origin/main:cloud/Dockerfile | grep -n 'RUN gzip'             # :82
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1100,1150p'
    git show origin/main:api/test/barkpark/tenancy/workspace_bundle_test.exs | sed -n '1292,1312p'
    git show origin/main:scripts/required-checks-generate.sh | sed -n '55,95p'
    gh pr view 8222 --json state,mergedAt
    gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.contexts'
