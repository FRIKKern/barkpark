# Re-derivation recipes — where a commit-distance / ancestry verdict can be COMPUTED (wave 21)

Verifier: `commit-distance-computation-site`. Every row re-derives from scratch. Local checkout at write
time was `0789ab90a`, **652 behind / 49 ahead of `origin/main` (`572d51e13`)** — so every fact about main is
taken with `git show origin/main:<path>`, never from the worktree.

| # | Claim | Command |
|---|---|---|
| 1 | The CP app shells out to git ZERO times | `git grep -c 'System.cmd("git"' origin/main -- cloud` (rc=1, no output) |
| 2 | The CP container mounts no source and no `.git` | `git show origin/main:cloud/docker-compose.yml \| grep -n 'volumes:\|- \./'` — only `cloud_pgdata`, `postfix_*` |
| 3 | No table orders barkpark-main shas; `deployments.git_ref` is a SITE content sha | `git show origin/main:cloud/priv/repo/migrations/20260627150100_create_deployments.exs` ; `git ls-tree -r --name-only origin/main -- cloud/priv/repo/migrations` |
| 4 | The CP GitHub client is App-credentialed and DEFAULTS TO `Fake` | `git grep -n 'GitHub' origin/main -- cloud/config` (config.exs:95-96 `client: GitHub.Fake`; runtime.exs:147 Real only when `GITHUB_APP_ID`+key set) |
| 5 | The INSTANCE already carries an unauthenticated GitHub compare client | `git show origin/main:api/lib/barkpark/self_update/client/github.ex \| sed -n '1,25p;55,75p'` |
| 6 | The public compare API answers ancestry + distance with no credential | `curl -s "https://api.github.com/repos/FRIKKern/barkpark/compare/6383ab46e...572d51e13" \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['status'],d['ahead_by'],d['behind_by'])"` → `ahead 2 0` |
| 7 | Anonymous budget is 60/h/IP | `curl -s -D- -o /dev/null ".../compare/A...B" \| grep -i 'x-ratelimit-limit'` → `60` |
| 8 | Identical shas → `identical 0 0`; unknown sha → HTTP 404 | `curl -s ".../compare/572d51e13...572d51e13"` ; `curl -s -o /dev/null -w "%{http_code}" ".../compare/dead…beef...572d51e13"` |
| 9 | An instance box fetches origin ONLY during a deploy/self-update | `git show origin/main:deploy/instance-deploy.sh \| sed -n '295,306p'` ; `git show origin/main:scripts/self-update.sh \| grep -n fetch` |
| 10 | `refresh_update_status/1` never reads `git_commit` | `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '3693,3760p'` |
| 11 | `@update_states` has exactly four rungs | `git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex \| sed -n '74,77p'` |
| 12 | Six live consumers of `update_state` | `git grep -n 'update_state' origin/main -- cloud/lib` |
| 13 | Adding a 5th rung blanks the rollout candidate set AND closes the staging canary gate | `cd cloud && CC=clang mix test <scratch>/rung_reshape_test.exs` (proof file body reproduced below) |
| 14 | Grace-expiry pause fires for any non-`current` state | `cd cloud && CC=clang mix test test/barkpark_cloud/autoupdate_rollout_worker_test.exs` → `bp-514 did not settle within grace (state=behind) — paused` |

## The scratch proof for row 13

Not committed anywhere in `cloud/test`. Recreate at any path and run it with
`cd cloud && CC=clang mix test <path>`; it needs only the ordinary `DataCase` sandbox.

Three assertions, all against the CURRENT four-rung tree (no source edit required — the hypothetical
rung is exercised by writing the raw column, which is exactly what a 5th rung would do):

1. `Barkpark.update_states()` == `["unknown","current","behind","disabled"]` and
   `update_status_changeset/2` rejects `"stale_commit"` with
   `[update_state: {"is invalid", [validation: :inclusion, enum: [...]]}]`.
2. `Registry.next_autoupdate_candidate("prod")` returns the box while it is `"behind"` and returns
   `nil` after the same row is set to `"stale_commit"` — the box becomes invisible to the rollout worker.
3. `Registry.staging_gate_open?()` is `true` with a `"current"` staging box and `false` once that box
   reads `"stale_commit"` — one canary in a new rung freezes the WHOLE prod fleet.
