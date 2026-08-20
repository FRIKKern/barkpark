# Re-derivation recipes — four words for absence, reconciled (2026-08-06)

Verifier assignment `vocabulary-reconcile`, deploy-reliability wave 4.
The primary checkout is **474+ commits behind `origin/main`** at measurement time, so every
source read goes through `git show origin/main:` or a detached worktree
(`git worktree add --detach <dir> origin/main`), never the working tree.

## A. `unreported` is MERGED, not in flight — the digest is one event stale

    gh pr view 9788 --json number,state,mergedAt,mergeCommit
    # MERGED 2026-08-06T11:46:59Z, mergeCommit 42f6c1e2c46da3633bcb75de5a664e007aafd7ae
    git rev-parse origin/main                      # 42f6c1e2c46da3633bcb75de5a664e007aafd7ae
    git show origin/main:cloud/priv/static/app.js | grep -n 'unreported'   # 7 hits, ATTENTION_RANK unreported:5

Deployed, not merely merged:

    curl -s https://barkpark.cloud/app.js | grep -c 'unreported'           # 7   (HTTP 200, 1,080,605 bytes)

## B. THE LIVE CONTRADICTION — same box, same minute, two words

    bp cloud status                 # muscle-1: "status":"degraded","rank":4,"bucket":"attention",
                                    #           "health_status":"unknown","agent_status":"offline"

Shipped SPA classifier, run against the identical field shape in a node:vm sandbox
(the harness's own sandbox recipe, `__app.test.mjs:38-80`, in a detached worktree at origin/main):

    cd <worktree>/cloud/priv/static && node -e '<harness sandbox> ; console.log(hooks.classifyBp(bp), hooks.attentionRank(bp), hooks.bucketOf(bp), JSON.stringify(hooks.statusOf(bp)))'
    # muscle-1 | SPA classifyBp = unreported | rank 5 | bucket attention
    # muscle-1 | SPA statusOf   = {"role":"neutral","label":"Never reported","detail":""}

CLI says **degraded (4)**. Console says **Never reported (5)**. Both live.

## C. The cross-surface vocabulary fixture is pinned by GO ONLY, and it now describes NEITHER surface honestly

    grep -rn 'attention_order' . --exclude-dir=.git --exclude-dir=node_modules
    # 8 hits under internal/cli/ (cloud_status_cmd.go:14,16,147 · cloud_status_cmd_test.go:67,114,123 · table.go:277)
    # ZERO hits under cloud/priv/static/*.mjs, cloud/lib, api/
    git show origin/main:cloud/priv/static/__fixtures__/attention_order.json
    # 8 states, "behind" at rank 5 — matches Go, NOT the shipped app.js (behind=6)

Double mutation, run in a detached worktree and restored (`git checkout --` after):
insert `unreported` at rank 5 into the fixture so it MATCHES app.js —

    node --test cloud/priv/static/__app.test.mjs | grep -E '^# (tests|pass|fail)'
    # 887 / 887 / 0   BEFORE and AFTER — the SPA harness cannot see the fixture at all
    CC=/usr/bin/clang go test -count=1 -run TestAttentionVocabulary ./internal/cli/
    # BEFORE: ok  0.352s
    # AFTER : cloud_status_cmd_test.go:93: fixture has 9 states, code has 8   FAIL

So the ONE file that claims to be the cross-surface spec can only ever describe Go, and
bringing it into agreement with the shipped console reds the Go gate.

## D. The four words, as shipped bytes

    git show origin/main:cloud/priv/static/app.js | sed -n '16981,17010p'
    #  usageUnavailableText: exception|deadline_exceeded|unreachable|bad_shape|too_many_datasets
    #  value = unmetered ? (unavailable ? "Could not measure" : "Not yet metered") : …
    git show origin/main:cloud/priv/static/app.js | sed -n '5254p'
    #  if (kind === "unreported") return { role:"neutral", label:"Never reported", detail: neverReportedEvidence(bp) };
    git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '150,255p'
    #  @unavailable_reasons ~w(exception deadline_exceeded unreachable bad_shape too_many_datasets)
    #  unavailable_meter/2 -> Map.put(meter(@unmetered, …), :unavailable_reason, …)  (CONDITIONAL key)
    git show origin/main:cmd/barkpark-agent/main.go | sed -n '300,310p'
    #  "A SWAPLESS BOX RETURNS (0, 0, nil) — NOT AN ERROR AND NOT THE -1 SENTINEL"
    #  "tell 'none configured' (0,0) from 'idle' (0, >0) from 'unmeasurable' (-1,-1)"

## E. The CLI's collapse is one struct field below the renderer

    git show origin/main:internal/cli/cloud_usage.go | grep -n 'unavailable'    # ZERO
    git show origin/main:internal/cloudclient/client.go | sed -n '1996,2008p'
    #  type UsageMeter struct { Value/Quota/WarnAt/OverAt/Source/MeasuredAt/PendingInvitations }
    #  no UnavailableReason field -> the reason is dropped at unmarshal, not at render.
    #  PendingInvitations *int `json:"pending_invitations,omitempty"` is the omitempty precedent, one line above.
    git show origin/main:internal/cli/cloud_usage.go | grep -n 'usageStateSeverity' -A 10
    #  over_limit 3 > near_limit 2 > unmetered 1 > live 0 — no rung for a FAILED read.

    bp task get cch-w29-bl-cli-usage-shows-crashed-vs-unmetered -o json   # lifecycle_status open, criteria 0/3, claim null
    bp task get cch-w34-bl-cli-usage-reason-dropped-in-the-client-struct  # same defect, cause named, 0/7,
                                                                          # criterion 1 DEMANDS a charter widening for
                                                                          # internal/cloudclient/client.go by name

## F. The closed-enum law binds the SPA and has a live instrument

    git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '2992,3018p'
    #  "statusOf is total over the CLOSED state enum" — KINDS pinned to 9, assert.deepEqual over hooks.attentionKinds
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'D386'
    #  "Inherited law for any new state: D33 (a CLOSED-ENUM test) … NO REMEDIATION rides on unknown"

## G. The two charter fences, verbatim

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '297,308p'  # D31 cession
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '735,746p'  # D42
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '866,880p'  # wave-3 slice table
    # D31 cedes "the console render path" / "the console half of the reader". It says NOTHING
    # about cloud/priv/static/__fixtures__/, and §C proves that tree's ONLY consumer is internal/cli.
    # The wave-3 table already grants s7 `cloud/priv/static/__fixtures__/` — i.e. the plan already
    # assumes what D31's text does not say.

## H. The CP pipe is still sealed at normalize/1 (nothing new can reach any word)

    git show origin/main:cloud/lib/barkpark_cloud/telemetry.ex | sed -n '58,92p'
    # fixed envelope: disk/db_size/cpu/mem/load1/req_per_s/p95_ms/backup/checks/dirty_tree/reported_at
    grep -rn 'swap' cloud/lib/    # zero telemetry hits (all compare-and-swap / swappable-adapter prose)
    grep -rn 'swap_used_percent\|beam_pss_bytes\|pg_top_relations' internal/ cmd/ cloud/ api/
    # producer side only: internal/agent/report.go:67,93,94,100 + cmd/barkpark-agent + their tests
