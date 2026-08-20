# cch wave 36 — collision + claims scan (re-derivation recipes)

Verifier lane `collision-and-claims`, 2026-08-06. origin/main head at the time: `070c7584b820745e1ac8377ca6926edef6d2f257`.
Every row below is a command that re-derives the finding from scratch. Nothing here is quoted from a prior wave.

## 1. Foreign task claims — the ledger has ZERO in_progress rows

`bp task list --status in_progress` does not exist (`task list` is aliased to `task ls`, which has no
`--status` flag and exits with `{"error":{"code":"usage",...}}`). The published data-query perspective
strips `claim.worker_id` / `claim.ts` to null, so it cannot answer the question either. Two commands that can:

    bp task prime --worker <any-worker> -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['counts']); print('my in_progress:',d['in_progress'])"
    # counts carries NO in_progress bucket: blocked/cancelled/considering/done/open only.

    # authoritative: replay the event feed and pair claims with closes.
    s=160000; while [ $s -lt 171500 ]; do bp task events --since $s --limit 500 -o json; echo; s=$((s+500)); done > /tmp/ev.jsonl
    # then: last task.claimed per doc_id, popped by task.closed | task.lease_expired.

The five docs that survive that pairing (pds-w40-residual-helper-hop, pds-w40-liveview-write-population,
pds-w41-scim-crosstenant-pin, pds-w40-residue-lens-can-fail, pds-w41-caps-component-gate) all read
`lifecycle_status: done` on a direct `bp task get` — their closes did not emit a paired event. Net: no live claim.

    bp task get pds-w40-liveview-write-population -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'], d.get('claim'))"

deploy-reliability's failure_class pill row:

    bp task get task-54326937e919e2cf -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'], d.get('claim'), d.get('assignee'), d.get('files'))"
    # -> open None None None   (open, unclaimed, unassigned; its `files` is null — it names app.js only in prose)

## 2. `.claude/worktrees/*/` is NOT a worktree list

257 directories match the glob; `git worktree list` reports 277 entries and they do not agree.
Empty/stale dirs make `git -C "$d" status` fall through to the PARENT repo, so a naive glob sweep
reports the primary checkout's dirt once per phantom directory (here: three times).

    git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //' > /tmp/wts.txt
    while read -r d; do [ "$d" = "/Volumes/SATECHI/github/barkpark" ] && continue; \
      s=$(git -C "$d" status --porcelain 2>/dev/null | grep -E 'cloud/priv/static|cloud/lib/barkpark_cloud/web'); \
      [ -n "$s" ] && { echo "== $d [$(git -C "$d" branch --show-current)]"; echo "$s"; }; done < /tmp/wts.txt

17 real worktrees carry cloud edits. NONE touches `cloud/priv/static/app.js`.
Only `wf_ff8529fe-dae-20` touches `cloud/lib/barkpark_cloud/web/auth.ex`, and that diff is
already-landed w35-s1 content (`forbidden(conn, required:.., scope:..)`), verifiable against main:

    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'forbidden(conn, required'

## 3. The primary checkout is the collision

    git rev-parse HEAD; git branch --show-current; git diff --stat -- cloud/priv/static/

`/Volumes/SATECHI/github/barkpark` sits on `main` at `a31faa52d` — behind `origin/main 070c7584b` —
with 219 uncommitted lines across app.js (+115), __app.test.mjs (+49), app.css (+41), index.html,
and `__preview__/cssom-heads.baseline`. The content is an unpushed team-picker / workspace-switcher
change (`renderTeamMenu`, `toggleTeamMenu`). Because the base is stale, a local read of app.js is
2504 diff-lines away from what will actually be merged:

    diff <(git show origin/main:cloud/priv/static/app.js) cloud/priv/static/app.js | grep -c '^[<>]'

## 4. The shared file with deploy-reliability wave 4 is router.ex, not __app.test.mjs

    python3 - <<'PY'
    import json,urllib.request
    d=json.load(urllib.request.urlopen("https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&limit=1000"))['result']
    for t in d['documents']:
        if t['_id'].startswith('dr-w4'): print(t['_id'], t['lifecycle_status'], t.get('files'))
    PY

dr-w4 roster (filed 2026-08-06 12:16–12:21Z): s1 deploy/, s2 internal/agent+cmd/, s4
**cloud/lib/barkpark_cloud/web/router.ex** + registry.ex + provisioning_test.exs, s6 deploy_ledger.ex,
s7 api telemetry. Zero rows name app.js or __app.test.mjs. Slots s3 and s5 are unfiled — the roster can still grow.

## 5. PR #6028

    gh pr view 6028 --json state,mergeable,mergeStateStatus,createdAt,updatedAt,author,files
    git show origin/main:scripts/ensure-bp.sh   # fatal: does not exist -> the PR is NOT landed
    git log --oneline origin/main --since=2026-07-23 -- cloud/priv/static/app.js | wc -l   # 46
    git log --oneline origin/main --since=2026-07-23 -- cloud/lib/barkpark_cloud/web/router.ex | wc -l # 36

OPEN / CONFLICTING / DIRTY, opened 2026-07-23T17:58Z, head last pushed 2026-07-31T04:24Z (6 days, not 13),
author FRIKKern (repo owner, a human PR — not a wave artifact). Its advisory `reland-check` is red;
that workflow is `continue-on-error: true` by construction and never blocks.

    gh pr list --state open --limit 100 --json number  # 7 open PRs total; only #6028 touches wave-36 files
