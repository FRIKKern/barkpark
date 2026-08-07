# dr-w5 — gate baseline on origin/main (2026-08-06)

Re-derivation recipes. Subject sha: `bf97452bb38488d04cfbb596c2528a3f34ad5baf`
("fix(cloud): the console stops rendering an owner as a member when /v1/me fails (#9850)",
authored 2026-08-06 16:41:19 +0200). Measured 2026-08-06 15:00–15:15Z.

## 0 — DO NOT measure in the primary checkout

    git rev-list --left-right --count origin/main...HEAD    # -> 503	48

The primary checkout is 503 commits BEHIND origin/main and 48 ahead. Every number
below was taken in a detached worktree:

    git worktree add --detach <scratch>/wt-main bf97452bb38488d04cfbb596c2528a3f34ad5baf

## 1 — Go, CI-equivalent (go-tests.yml runs `go vet ./...` + `go test -race ./...`)

    cd <scratch>/wt-main
    CC=clang go build ./...            # rc 0, zero output
    CC=clang go vet ./...              # rc 0, zero output
    CC=clang go test -race ./...       # rc 0; 29 ok, 0 FAIL, 0 DATA RACE, 9 no-test-files
    CC=clang go test ./internal/cli/...  # rc 0; 4 ok (cli 22.5s, cloud 0.99s, azure 0.64s, setup 2.62s)

Capture rc BEFORE any pipe (`> out 2>&1; echo $?`) — `cmd | tail; echo $?` reports tail.

## 2 — Node console harness

    cd <scratch>/wt-main
    node --check cloud/priv/static/app.js          # rc 0
    node cloud/priv/static/__app.test.mjs          # rc 0; 1..914  pass 914  fail 0

Charter D57 quotes "887/887/0". The harness is now **914**; any D57-derived count is stale.

## 3 — Per-check-run status of main's head (NOT the run rollup)

    SHA=$(git rev-parse origin/main)
    gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs?per_page=100" \
      --jq '.check_runs[] | "\(.status)\t\(.conclusion)\t\(.name)"' | sort

`per_page=100` is REQUIRED — the default 30 silently truncated 34 rows and hid
"Elixir gate" and "Doc budgets + anchors" on the first pass.
Result: **32 success, 3 skipped, 0 failure, 0 null.** ("Test (Elixir 1.18.1 / OTP 27.0)"
was `in_progress` at 15:02Z and concluded `success` by 15:07Z — poll, don't conclude.)

## 4 — Required contexts (re-derived, not inherited)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{contexts:.required_status_checks.contexts, enforce_admins:.enforce_admins.enabled}'
    # {"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"],
    #  "enforce_admins":true}

`go vet + test` is NOT required, and it did not run on this sha at all (go-tests.yml
`on.push.paths` is `**/*.go|go.mod|go.sum|templates/**|internal/pdrender/testdata/**|
docs/cli/fixtures/**`; #9850 was cloud-only). D66 holds verbatim.

## 5 — The binary-provenance trap, and why `make cli-install` does NOT fix it here

    bp version                                   # commit f59aaf717, build 2026-07-31
    strings $(which bp) | grep -c 'pss_bytes\|top_relations\|cpu_cores'   # 0
    git rev-list --count f59aaf717..origin/main  # 321
    git log --oneline f59aaf717..origin/main -- internal/cli internal/cloudclient internal/agent | wc -l   # 27
    grep -rn "cpu_cores" internal/ | wc -l       # 0  <- PRIMARY CHECKOUT
    grep -rn "cpu_cores" <scratch>/wt-main/internal/ | wc -l   # 3  <- origin/main

`make cli-install` builds from the LOCAL checkout (Makefile:161-176, `go build ./cmd/barkpark`).
Run in the primary checkout it installs a bp that is STILL blind to the vitals fields.
A wave-5 builder must build bp from a worktree at origin/main, or verify `strained`
against a binary that structurally cannot show it.

    make doctor    # 4 issues: 503 behind / 48 unpushed / release cli-v1.16.0 744 commits
                   # behind / installed bp predates Go changes on origin/main

## 6 — The two attention ladders, verbatim on origin/main

    grep -n "ATTENTION_RANK" -A 5 <wt>/cloud/priv/static/app.js     # 9 rungs, behind:6
    grep -n "bucketOf" -A 4  <wt>/cloud/priv/static/app.js          # r<=6 attention : r<=8 inflight : healthy
    sed -n '75,95p' <wt>/internal/cli/cloud_status_cmd.go           # attentionRankOrder: 8 rungs, no unreported
    cat <wt>/cloud/priv/static/__fixtures__/attention_order.json    # 8 states, behind rank 5

Three surfaces, three different ladders (8 / 8 / 9). Charter D56 specifies a 10-rung
ladder with buckets "attention <=6, in-flight 7-9" — which puts `behind` (D56 rank 7)
in IN-FLIGHT, while shipped app.js has it in ATTENTION. D56's bucket integers must be
amended to attention <=7, in-flight 8-9, healthy 10 to stay render-neutral.
