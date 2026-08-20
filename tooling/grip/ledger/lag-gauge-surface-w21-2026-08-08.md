# Re-derivation recipes — w21 verifier lane `lag-gauge-surface` (2026-08-08)

All commands run from a worktree detached at `origin/main` (the primary checkout was
652 commits behind and NOT an ancestor of origin/main at the time of writing —
`git merge-base --is-ancestor HEAD origin/main` exited 1). Create one with:

    git worktree add --detach /tmp/w21-lag origin/main

## R1 — the delivery block is DARK in production (headline)

    T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])")
    curl -s -o /tmp/op.json -w '%{http_code}\n' -H "Authorization: Bearer $T" \
      "https://barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-01T00:00:00Z&to=2026-08-08T00:00:00Z"
    # → 403 {"error":"forbidden","scope":"platform","required":"platform_operator"}
    curl -s -H "Authorization: Bearer $T" \
      "https://barkpark.cloud/v1/deploy-ledger/census?from=2026-08-01T00:00:00Z&to=2026-08-08T00:00:00Z" \
      | python3 -c "import sys,json;print('has delivery:', 'delivery' in json.load(sys.stdin))"
    # → has delivery: False

Rendered consequence (build bp from the worktree first — the installed `bp` predates
the verb and answers `unknown cloud command "deployments"`):

    (cd /tmp/w21-lag && CGO_ENABLED=0 go build -o /tmp/bp21 ./cmd/barkpark)
    /tmp/bp21 cloud deployments -o table | grep -A1 '^delivery'

Code sites: `cloud/lib/barkpark_cloud/web/router.ex:3610` (team route, no `:delivery`)
vs `:3556` → `deploy_census_json/2` at `:9523` (operator route, adds `:delivery`).

## R2 — `delivery/3` is fleet-wide, with no site scope

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '1257,1280p'

`opts` accepts only `:site_limit` and `:as_of`. The query filters on `inserted_at`
and `environment` only. Emitting it verbatim from the team route cross-tenant-leaks
other teams' `site_id`s in the `sites` node.

## R3 — the control plane has no ROW on any human surface

    /tmp/bp21 cloud status -o table            # six rows, all customer instances
    curl -s -H "Authorization: Bearer $T" https://barkpark.cloud/v1/barkparks \
      | python3 -c "import sys,json;print([b['slug'] for b in json.load(sys.stdin)['barkparks']])"

`digest_email.ex` renders `[Registry.Barkpark]` only (`instance_line/1`, `:138`), so
the same six rows. Neither surface can host a CP-keyed gauge without a new row concept.

## R4 — `serving_since` has no history

    git show origin/main:cloud/lib/barkpark_cloud/health.ex | sed -n '54,74p'
    git grep -n 'serving_since' origin/main -- cloud | grep -v test

Computed live from `:erlang.system_info(:start_time)`; persisted nowhere. Also: it is
PROCESS uptime, not sha-liveness — a bare restart resets it and makes the gauge read
BETTER than reality.

## R5 — the 5h34m outlier is CI queue starvation, not a deploy stall

    gh run view 31121348964 --json createdAt,updatedAt,conclusion,headSha
    gh run view 31121348964 --json jobs \
      --jq '.jobs[] | [.name,.startedAt,.completedAt] | @tsv'

Run created 16:52:49Z; the `changes` job's first step began 22:17:36Z (5h24m47s of
queue). Once started, the whole deploy took 8m52s. Fifteen unrelated workflows created
16:43–16:53Z all completed 22:17–23:32Z — repo-wide runner starvation.

    gh api -X GET '/repos/FRIKKern/barkpark/actions/runs' -f created=2026-08-06 \
      -f per_page=100 --paginate --jq '.workflow_runs[] | [.id,.name,.created_at,.updated_at] | @tsv'

## R6 — live merge-to-serving lag (CP)

    gh pr list --state merged --limit 1 --json number,mergedAt,mergeCommit
    curl -s https://barkpark.cloud/health

2026-08-08: #10616 merged 02:42:39Z (`572d51e13`); `/health` at 03:14:54Z reported
`git_sha=572d51e13…`, `serving_since=02:45:42.628915Z` → **3m03.6s**.

## R7 — instance commit distance (D343 re-take)

    for c in f3ee2984 95210658 e221e7dd c8016810 2673eb00; do
      echo "$c behind=$(git rev-list --count $c..origin/main)"; done

gyl 227 · jarl 592 · dooodo 886 · gyldendal 2468 · guerrilla 4 · muscle-1 NULL —
all six `update_state: current`, all `0.2.25`.
