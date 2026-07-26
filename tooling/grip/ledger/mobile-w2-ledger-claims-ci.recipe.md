# mobile-w2-ledger-claims-ci — re-derivation recipes (Barkpark Tasks mobile, wave 2 verify)

Read-only. Proves: per-child claim state on epic task-c31a4f0a6c5be3ea, main's own
CI gates, PR #6024's mergeability, and task-e8ca8c5b9f99e9f8's GitHub sync state.
No bp mutations, no commits.

## (a) Per-child claim sweep — claim lives under `.doc`, NOT top level

The survey's "all-None" result came from reading `.claim` at the top level. `bp task get`
returns an envelope `{ok, doc, children, child_count}`; the claim is `.doc.claim`.

    bp task get task-c31a4f0a6c5be3ea -o json | python3 -c "import json,sys;[print(c['doc_id'],c['lifecycle_status'],c['execution_class']) for c in json.load(sys.stdin)['children']]"

    for s in $(bp task get task-c31a4f0a6c5be3ea -o json | python3 -c "import json,sys;[print(c['doc_id']) for c in json.load(sys.stdin)['children']]"); do \
      bp task get "$s" -o json | python3 -c "
    import json,sys
    d=json.load(sys.stdin)['doc']; c=d.get('claim')
    print('%-30s | lifecycle=%-6s | assignee=%-30s | %s' % ('$s', d.get('lifecycle_status'), d.get('assignee'),
      ('worker=%s epoch=%s released_by=%s' % (c.get('worker'),c.get('epoch'),c.get('released_by'))) if c else 'CLAIM=null'))"; done

Result 2026-07-26: 26/26 enumerated. 8 lifecycle=open. Every open child has `claim=null`
EXCEPT `t3code-upgrade-epic-candidate`, whose claim is RELEASED
(`worker: null, epoch: 2, released_by: "lead-session", released_at 2026-07-25T22:58:10Z`).
=> ZERO live foreign claims on the open set. All 18 done children carry historical
un-released claims (mob-lead / epic-builder-* / mob-w2r3-*) — expected, not blocking.

## (b) main's own gates

    gh run list --workflow=mobile.yml --branch=main -L 5
    gh run view 30152096565 --json headSha,conclusion,jobs -q '.headSha,.conclusion,(.jobs[]|"\(.name)\t\(.conclusion)")'
    gh run list --workflow=elixir.yml --branch=main -L 5
    SHA=$(git rev-parse origin/main); gh run list --branch=main -L 25 --json workflowName,conclusion,headSha -q ".[]|select(.headSha==\"$SHA\")"

mobile.yml is PATH-FILTERED (apps/mobile/**, pnpm-workspace.yaml, .github/workflows/mobile.yml),
so it does NOT run on every main tip. Latest mobile-touching commit = cd26bbbe7 → run
30152096565 SUCCESS (single job "Typecheck + lint + jest"). elixir.yml on origin/main tip
ef8ff35d = run 30175399916 SUCCESS (Test + Prod compile gate green; Format advisory red,
a standing main-wide advisory). One commit earlier (48bf746a) elixir Test FAILED — main
self-healed on the next commit.

## (b2) jest baseline re-derived from an actual run (charter R11)

    gh run view 30152096565 --log | grep -E "Test Suites:|Tests:"
    # Test Suites: 13 passed, 13 total
    # Tests:       165 passed, 165 total

165/165 on cd26bbbe7 is the live baseline. The 85/85 figure written into
mob-bl-chat-tab-polish AC5 is the mob-w2-chat-tab-era number and is STALE.

## (c) PR #6024 (S7's TUI leg predecessor)

    gh pr view 6024 --json state,mergeable,mergeStateStatus,updatedAt,commits,files,statusCheckRollup
    git fetch origin 'refs/pull/6024/head:refs/tmp/pr6024' && git rev-list --left-right --count origin/main...refs/tmp/pr6024

OPEN / mergeable=MERGEABLE / mergeStateStatus=UNSTABLE. 57 behind, 2 ahead of origin/main.
Last commit 2026-07-23T15:42:32Z — untouched for 3 days (STALLED, not blocked). All
required checks green; the only reds are advisory (mix format) + Vercel preview builds.
Files: internal/chat/{keys,model,model_test,reduce,reduce_test}.go — the D77 settle-race fix.

## (d) task-e8ca8c5b9f99e9f8 GitHub sync

    bp task get task-e8ca8c5b9f99e9f8 -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['content']['github'])"
    gh issue view 6127 --json number,state,title,updatedAt,labels

link = {issue: 6127, repo: FRIKKern/barkpark, state: "synced", synced_rev: 64b644ae…} —
NOTE: **no `synced_fingerprint`**. Per api/lib/barkpark/plugins/github/mirror_job.ex:53-57,
absent a stored fingerprint the reconcile "records nothing this pass, just PATCH + stamp the
fingerprint (rolls forward, no backfill)" — so a Decide rewrite re-PATCHes issue 6127's
title/body/labels with NO out_of_band_edit conflict. Mirror is live: the epic candidate's
issue 6133 updated 2026-07-25T22:58:34Z, ~24s after its claim release at 22:58:10Z.
