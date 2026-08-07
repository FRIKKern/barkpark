# W14 — what `bp cloud site status` VERBATIM prints (2026-08-07)

Re-derivation recipes. Binary built from **origin/main 77cf2060c** in a scratch
worktree — the primary checkout's local `main` (0789ab90a) is BEHIND origin/main
and would have produced a stale binary, which is the exact defect that made every
prior capture untrustworthy.

## 0. Build the binary that is actually origin/main

    git -C /Volumes/SATECHI/github/barkpark worktree add /abs/path/wt-w14 --detach origin/main
    cd /abs/path/wt-w14 && make cli-build      # -> dist/bp, stamped commit=77cf2060c
    ./dist/bp version                          # {"cli_version":"dev","commit":"77cf2060c"}

NOTE: `git worktree add` with `-C <repo>` resolves a RELATIVE target against the
repo, not your cwd. Pass an ABSOLUTE path or you create a worktree inside the repo.

## 1. THE FORMAT TRAP — why seventeen reports never read the sentence

`bp` picks output format by TTY: `internal/cli/output.go:74-80` — explicit `-o`
wins, else `isTTY ? "table" : "json"`. Every piped/captured run gets **raw JSON**.
The human paragraph exists but is invisible to agents, CI, and `| tee`.

PTY-free recipe for the human render (use this in every proof):

    ./dist/bp cloud site status <site> -o table

Or force a real PTY: `script -q /tmp/out.txt ./dist/bp cloud site status <site>`

## 2. Finding the case you need (no admin gate required)

`bp cloud site status` shows only the newest + live row, so the population must be
found from the user-scoped list endpoint (`user` scope, not platform):

    CT=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -H "Authorization: Bearer $CT" "https://api.barkpark.cloud/v1/sites?team_id=506f035e-08f4-4b49-9038-86735eb4c0ef"
    curl -s -H "Authorization: Bearer $CT" "https://api.barkpark.cloud/v1/sites/<site-id>/deployments?limit=100"

Rows carry `deferral_depth`, `deferral_bound`, `deferral_cause`, `failure_class`,
`content_rev`, `status`, `trigger`, `source`. Paginate with `next_cursor`.

Case map as of 2026-08-07T12:30Z (13 sites, one team):
- currently deferring: `astro-search`, `live-auto` (churn ~60s; re-scan before use)
- abandoned chains present but NOT newest: `search` (47 of 523 chains, full 2000-row history)
- failed, never live: `perfect-demo`, `nodeproof-20260718-73191`
- zero deployments: `auto-proof`
- newest FAILED over an older LIVE: **population empty** — no site is in this state

## 3. The fleet arm

    ./dist/bp cloud deployments      # exists; exits 3 with an honest 403 refusal
    ./dist/bp cloud status -o json   # top keys: barkparks, buckets, count, ok — NO deploy arm, NO sites

## 4. Re-derived on origin/main

    git grep -c deploy_rate origin/main -- cloud/test/     # exit 1 — no guard
    git grep -c deploys_failing origin/main -- internal/   # exit 1 — no deploy arm
    git grep -ln PublishClock origin/main                  # module + own test + docs only
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1416,1420p'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n '@refusal'
    grep -rn 'DeferralDepth\|DeferralBound\|DeferralCause' internal/cli/ | grep -v _test   # EMPTY

## 5. Go tests in this repo need the real compiler

`cc` is shadowed by a Claude wrapper (`error: unknown option '-E'`). Use:

    CC=/usr/bin/clang CGO_ENABLED=0 go test ./internal/cli/ -run 'TestSiteStaleness|TestSiteDeferral' -count=1
