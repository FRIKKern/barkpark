# dr-w12 verifier — #10129's REAL conflict set vs today's 11-rung main, and the four ladder pins mutation-proven (2026-08-07)

Re-derivation recipes. `origin/main` at derivation time = `ba712a4b29ce5e6721b81a93343182654e47918f`.
`pr10129` head = `514ff5c6f664a7b1af6dfc7342eafafc0700d8a6`. Merge-base = `8ae30b34b` (2026-08-07 06:09:12).

**NEVER measure the ladder in the primary checkout.** It is `ahead 49, behind 561` and still carries the
EIGHT-rung `attentionRankOrder`. Every command below runs from a clean extraction.

## 0. Clean extraction (read-only; no worktree, no branch, no git state change)

    SP=/tmp/mainroot; rm -rf $SP; mkdir -p $SP
    cd /Volumes/SATECHI/github/barkpark && git archive origin/main | tar -x -C $SP

## 1. The conflict set — SIX paths, unchanged from wave 11

    git fetch origin 'refs/pull/10129/head:pr10129' -f
    git merge-tree --write-tree origin/main pr10129        # exit 1
    # CONFLICT (content) x6:
    #   cloud/priv/static/__fixtures__/attention_order.json
    #   internal/cli/cloud_status_cmd.go
    #   internal/cli/cloud_status_cmd_test.go
    #   internal/cli/testdata/attention_order_cases.json
    #   internal/cloudclient/client.go
    #   internal/semrole/semrole.go
    # Auto-merging (NO conflict): cloud/lib/barkpark_cloud/web/router.ex
    # Clean adds: cloud/lib/barkpark_cloud/deploy_ledger.ex, cloud/test/.../deploy_ledger_test.exs

Materialise the hunks without touching the repo — stage blobs are in the merge-tree output:

    git merge-tree --write-tree origin/main pr10129 > /tmp/mt.txt
    # rows are: 100644 <blob> <stage 1=base 2=main 3=pr> <path>
    git cat-file blob <blob>            # per stage
    git merge-file -p --diff3 -L MAIN -L BASE -L PR10129 <s2> <s1> <s3>

## 2. The three ladders that actually exist on origin/main

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '/^var attentionRankOrder/,/^}/p'
    # 11: removal_failed failed suspended degraded strained filling unreported behind removing provisioning ok
    git show origin/main:cloud/priv/static/__fixtures__/attention_order.json     # 11 states, ok=11
    sed -n '5481,5485p' $SP/cloud/priv/static/app.js
    # SPA is still NINE: unreported:5, behind:6, removing:7, provisioning:8, ok:9 — no strained, no filling
    grep -c 'attention_order' $SP/cloud/priv/static/__app.test.mjs        # 0 — no edge joins fixture<->SPA
    cd $SP/cloud/priv/static && node __app.test.mjs | tail -6            # 943 pass / 0 fail, blind to the Go ladder

    git show pr10129:internal/cli/cloud_status_cmd.go | sed -n '/^var attentionRankOrder/,/^}/p'
    # 10: ... degraded 4, deploys_failing 5, behind 6, removing 7, provisioning 8, unmetered 9, ok 10

## 3. D150's ratified basis is OBSOLETE — read its own words

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '2967,2977p'
    # "Landed ladder on origin/main is EIGHT rungs (the eleven-rung D69 ladder is unmerged #9887),
    #  so wave 10 builds on the 8-rung basis" — #9887 merged 2026-08-07T06:13:52Z.
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '733,742p'   # D42
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n 'D147'      # citation errata

## 4. MUTATION A — one fixture rank integer reds the vocabulary pin

    # edit $SP/cloud/priv/static/__fixtures__/attention_order.json: "behind" rank 8 -> 9
    cd $SP && CC=clang go test ./internal/cli/ -run 'Attention'
    # FAIL TestAttentionVocabularyMatchesFixture
    #   cloud_status_cmd_test.go:393: behind: attentionRank = 8, fixture rank 9
    # NOTE: TestAttentionLadderIsElevenRungs stays GREEN — it pins NAMES, not fixture ranks.

## 5. MUTATION B — the CONSISTENT 13-rung renumber reds THREE pins at once

    # fixture: insert deploys_failing before behind and unmetered before ok, renumber 1..13
    #          (unmetered tone "" exactly as pr10129 authors it)
    # cloud_status_cmd.go: insert the same two names into attentionRankOrder
    cd $SP && CC=clang go test ./internal/cli/ -run 'Attention|Rank'
    # FAIL TestAttentionBucket
    #   :118: bucket table covers 11 states, the ladder has 13
    # FAIL TestAttentionLadderIsElevenRungs
    #   :142: ladder has 13 rungs, want 11: [... unreported deploys_failing behind removing provisioning unmetered ok]
    # FAIL TestAttentionVocabularyMatchesFixture
    #   :408: deploys_failing: statusRole = "", fixture tone "warn"
    #   :405: unmetered: fixture tone must be a real semantic role (ok/info/warn/danger), not empty

The `:405` line is the decisive one: main's TONE-HOLE guard (landed AFTER 10129's base) makes
`{"state":"unmetered","tone":""}` — the row 10129 ships verbatim — **illegal**, independent of rank.

## 6. MUTATION C — the order-cases pin loses on a swap

    # in $SP/internal/cli/testdata/attention_order_cases.json swap strain-1 / fill-1 in expected_order
    cd $SP && CC=clang go test ./internal/cli/ -run 'RankBarkparksFixture'
    # FAIL :454 rank order mismatch at 5 — got [... deg-2 strain-1 fill-1 ...] want [... deg-2 fill-1 strain-1 ...]

## 7. The fifth pin: semrole

    git show pr10129:internal/semrole/semrole.go | grep -n 'case "degraded"'
    # -> case "degraded","unknown","suspended","inactive","near_limit","deploys_failing"
    #    i.e. a "theirs" resolution DELETES strained/filling/unreported from the warn family.
    grep -n 'strained\|filling\|unreported' $SP/internal/semrole/semrole_test.go   # lines 21,40,41 pin all three -> "warn"

## 8. Restore proof (mutations lived ONLY in /tmp; the repo was never edited)

    diff <(git show origin/main:internal/cli/cloud_status_cmd.go) $SP/internal/cli/cloud_status_cmd.go
    diff <(git show origin/main:cloud/priv/static/__fixtures__/attention_order.json) $SP/cloud/priv/static/__fixtures__/attention_order.json
    diff <(git show origin/main:internal/cli/testdata/attention_order_cases.json) $SP/internal/cli/testdata/attention_order_cases.json
    cd $SP && CC=clang go test ./internal/cli/ ./internal/semrole/ -run 'Attention|Rank|Role|For'   # both ok
