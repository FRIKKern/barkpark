# PDS w24 verifier [unchecked-96-by-content] — re-derivation recipes

All rows derived 2026-07-30 against `origin/main` @ **a4e00494eef09e720846ba8e7387f7a5bfef5e3d**
(the primary checkout was at a31faa52d, i.e. BEHIND main — every `git` fact below is taken with
`git show origin/main:…` or against a `git archive origin/main` snapshot, never the worktree).
Ledger host: guerrilla.barkpark.cloud; installed `bp` = commit 2c94b0ba7, built 2026-07-28T22:06:02Z.

## R1 — the Sobelow row is LIVE (refutes any "closed by c66008ae2" reading)

    gh api repos/FRIKKern/barkpark/actions/runs/30545345545/jobs \
      -q '.jobs[] | select(.conclusion=="failure") | .name'
    gh api repos/FRIKKern/barkpark/actions/jobs/90879957375/logs | sed -n '1373,1537p' | grep -c Confidence
    # => 19 unskipped findings on main @ 1050229a4 (2026-07-30 13:06Z); job exits 1

Split by file (`grep '^File:' | sort | uniq -c`): workspace_bundle.ex 10, janitor.ex 6, router.ex 3.

## R2 — the two scripts DO handle line shift; the residue they can see is zero

    W=$(mktemp -d); git archive origin/main api/scripts api/.sobelow-skips api/lib | tar -x -C $W
    ( cd $W && bash api/scripts/sobelow-baseline-staleness-check.sh )   # exit 0, 57 entries, 0 STALE
    ( cd $W && bash api/scripts/sobelow-baseline-staleness-check.sh --selftest )  # exit 0, 8/8 fixtures

The mutation fixture named `one entry shifted by ONE line` expects exit 1 — line shift is the
ratchet's *subject*, not a gap. `reconcile.sh` covers the *other* complaint (inline-waiver
swallowing, via the load-bearing `--skip`). Neither can see "the FINDING moved while the pinned
line still holds a construct of the same type" — which is exactly the residue in R1.

Do NOT run the local worktree copy and quote it: at a31faa52d the same script reports 31 STALE
of 89 entries. That is the PRE-`c66008ae2` baseline, not main.

## R3 — Cluster A + the umbrella row are free-closed by 6f4ca7904 (#6553), proven by mutation

    W=$(mktemp -d); git archive origin/main scripts | tar -x -C $W
    bash $W/scripts/pds-scratch-target_test.sh            # exit 0 · 32 PASS · 0 FAIL
    git show 6f4ca7904^:scripts/pds-scratch-target.sh > $W/prefix.sh
    PDS_SCRATCH_TEST_SCRIPT=$W/prefix.sh bash $W/scripts/pds-scratch-target_test.sh   # exit 1 · 21 FAIL
    ( cd $W && bash scripts/pds-crown-launch.sh selftest )  # exit 0 · "57 ok · 0 FAIL", §9 present

## R4 — `bp cloud deploy` has no non-dry-run envelope, and the help says it does

    git show origin/main:internal/cli/cloud_deploy_cmd.go | grep -c renderJSON      # => 1
    git show origin/main:internal/cli/cloud_deploy_cmd.go | sed -n '/^func deployDryRun/,/^}/p'
    git log origin/main --oneline -S'or the result as an envelope' -- internal/cli/cloud_deploy_cmd.go
    # => 4901d8498 (#2074) — the help line predates the read-back entirely

The verb lives at `internal/cli/cloud_deploy_cmd.go` (709 lines). `internal/cli/cloud/deploy.go`
does not exist — do not cite it.

## R5 — `bp search` does NOT dead-end on a bare noun

    bp search "sobelow"
    # => note: `search` has one verb — running `barkpark search query`
    # => count 212, exit 0

The "the `query` sub-verb is REQUIRED, otherwise exit 2" premise is FALSE for bp @ 2c94b0ba7.

## R6 — three more rows re-confirmed LIVE by content

    bash scripts/go-literal-check.sh --selftest   # exit 1 on macOS: "RED did not name the planted file:line"
    bash scripts/go-literal-check.sh              # exit 0 — the CHECK is fine, only the selftest false-reds
    git show origin/main:scripts/pds-pull-proof.sh | grep -n DEPLOYED_SHA   # only :637, inside advice text
    git show origin/main:scripts/pds-climb-preflight.sh | sed -n 208p      # the honouring line, other script
    git show origin/main:scripts/check-doc-budgets.sh | grep -c '^scripts/'  # => 0, while 17 scripts/*.md declare budgets
    git show origin/main:bin/barkpark | sed -n '142,151p'   # server_running = pidfile + kill -0; listener_pid is the ELSE

## R7 — operational constraint for the movement-2 census script

Every `bp` invocation re-acquires `GET /v1/capabilities`. A 3-worker BFS over the epic closure
tripped the limiter within ~2 minutes and then 429'd plain single reads for ~90 s:

    bp: acquire manifest from https://guerrilla.barkpark.cloud/v1/capabilities:
        fetch manifest: unexpected status 429 — rate_limited (retry_after 1)

A census MUST pin `BARKPARK_MANIFEST=<file>` (or `--manifest`), run serially, and treat
`{"ok":false,"error":{"code":"rate_limited"}}` as RETRY — it parses as valid JSON, so a naive
`json.load()` success check reads a rate-limit as data and silently under-counts the board.

## R8 — level-1 roster at this instant

    bp task get task-2ac1f95237c4a8e5 -o json | \
      python3 -c 'import json,sys;o=json.load(sys.stdin);from collections import Counter;
      print(o["child_count"], Counter(c["lifecycle_status"] for c in o["children"]))'
    # => 179  Counter({open: 101, done: 58, cancelled: 10, considering: 10})  → 111 LIVE, 100 of them 0/N

This is ONE LEVEL only and is not the board — the closure is larger. Quoted here so a later
reader can see the level-1 number moved (178→179, 110→111 live) between 2026-07-30 morning and
16:4xZ, which is why every census must name its instant.
