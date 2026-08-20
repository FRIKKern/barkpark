# dr-w10 — the attention ladder is pinned twice and neither pin can see the other (MUTATION-PROVEN)

Verifier re-derivation recipes, 2026-08-07. All commands run from a CLEAN extraction of
`origin/main` (the primary checkout is **534 commits behind** and its `app.js` still carries the
8-rung ladder — never measure the ladder in the primary checkout).

## 0. Build the clean extraction

    SP=/tmp/mainfull; rm -rf $SP; mkdir -p $SP
    cd /Volumes/SATECHI/github/barkpark && git archive origin/main | tar -x -C $SP

## 1. The three ladders on origin/main

    git show origin/main:cloud/priv/static/__fixtures__/attention_order.json      # 8 states, ok=8
    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '76,88p'       # attentionRankOrder, 8
    git show origin/main:cloud/priv/static/app.js | sed -n '5295,5299p'           # ATTENTION_RANK, 9

## 2. Baseline greens

    cd $SP && CC=clang go test ./internal/cli/... -run 'Attention|Rank|Vocabulary|Fixture' -v
    cd $SP/cloud/priv/static && node --check app.js && node __app.test.mjs | tail -8   # 919/919

Running `__app.test.mjs` from a PARTIAL extraction (only `cloud/priv/static`) produces 15
ENOENT-class failures — an extraction artifact, not a red on main. Extract the whole tree.

## 3. MUTATION A — rewrite the fixture to the SPA's 9-rung ladder

    # edit $SP/cloud/priv/static/__fixtures__/attention_order.json: insert unreported=5, shift to ok=9
    cd $SP/cloud/priv/static && node __app.test.mjs | tail -8    # STILL 919/919 pass  <-- the hole
    cd $SP && CC=clang go test ./internal/cli/ -run 'Attention'  # FAIL: "fixture has 9 states, code has 8"

## 4. MUTATION B — move the SPA ladder, leave the fixture alone

    # in $SP/cloud/priv/static/app.js set unreported:10, behind:5, removing:6, provisioning:7
    cd $SP && CC=clang go test ./internal/cli/ -run 'Attention|Rank'   # ok — Go is blind to app.js
    cd $SP/cloud/priv/static && node __app.test.mjs | grep '^not ok'   # 6 JS reds (139-144)

## 5. MUTATION C — a classified state with NO `ATTENTION_RANK` entry

    # in $SP/cloud/priv/static/app.js delete `removal_failed: 1,` from ATTENTION_RANK
    cd $SP/cloud/priv/static && node __app.test.mjs | grep -A10 '^not ok 142'
    # error: Expected values to be strictly equal:  + 'healthy'   <-- rank-1 state buckets HEALTHY

## 6. Go append/unknown-rung behaviour (probe, not a shipped test)

    cat > $SP/internal/cli/zz_probe_test.go <<'EOF'
    package cli
    import "testing"
    func TestProbeAppendedRungBehaviour(t *testing.T) {
        orig := attentionRankOrder
        defer func() { attentionRankOrder = orig }()
        attentionRankOrder = append(append([]string{}, orig...), "deploy_failing")
        t.Logf("rank(deploy_failing)=%d rank(ok)=%d bucket=%q",
            attentionRank("deploy_failing"), attentionRank("ok"), attentionBucket("deploy_failing"))
        t.Logf("unknown rank=%d bucket=%q", attentionRank("never_declared"), attentionBucket("never_declared"))
    }
    EOF
    cd $SP && CC=clang go test ./internal/cli/ -run ProbeAppendedRung -v
    # rank(deploy_failing)=9 rank(ok)=8 bucket="attention"   -> bucket fails SAFE, rank fails UNSAFE

## 7. Why nothing catches the drift

    git show origin/main:cloud/priv/static/__app.test.mjs | grep -c 'attention_order'   # 0
    git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '3286,3292p'         # KINDS is an inline literal
    git grep -ln 'attention_order' origin/main -- '*.mjs' '*.js' '*.ex' '*.exs'         # (empty)

Go asserts fixture ↔ Go. JS asserts inline literal ↔ JS. No edge joins fixture ↔ JS.
The comment at `internal/cli/cloud_status_cmd.go:14-15` claims the node harness asserts the same
file "from wave 3" — a phantom cross-surface citation, the same defect shape as the phantom D69.
