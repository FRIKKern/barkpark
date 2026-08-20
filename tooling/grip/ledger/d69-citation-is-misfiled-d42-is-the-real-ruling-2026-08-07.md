# D69 is misfiled; D42 is the landed ruling — re-derivation recipes (2026-08-07)

Verifier lane `phantom-D69-unmetered-ruling`, deploy-reliability wave 10.

## 1. origin/main's D69 does NOT say "unmetered is not a rung"

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md > /tmp/ch.md
    sed -n '1416,1436p' /tmp/ch.md

D69 = "AMENDS D53 NARROWLY: THE DISK GETS ITS OWN RUNG `filling`". Zero words about unmetered.

## 2. The ruling the code MEANS is D42, at charter line 735

    sed -n '735,745p' /tmp/ch.md

"D42 — NO NEW `unmetered` ATTENTION STATE. The existing `degraded` arm already covers every box that
cannot be read. … a nil or `-1` vital NEVER produces `strained`."

## 3. origin/main stops at D105; D145 is unmerged wave text

    grep -c '^- \*\*D[0-9]' /tmp/ch.md            # 105
    grep -c '^- \*\*D[0-9]' .claude/workflows/bp-deploy-reliability-charter.md   # 145
    sed -n '2869,2881p' .claude/workflows/bp-deploy-reliability-charter.md       # D145 cites D42, not D69

## 4. #9887's tests pass, and TestUnmeteredMarker really pins unmetered -> "ok"

Worktree `scratchpad/w9v1` is at `aa19dcca3` (= `gh pr view 9887 --json headRefOid`) but is DIRTY with
another agent's p95 arm. Use a `go test -overlay` against `git show HEAD:` copies — no repo write:

    cd <w9v1>
    git show HEAD:internal/cli/cloud_status_cmd.go > /tmp/pristine/cloud_status_cmd.go
    git show HEAD:internal/cloudclient/client.go   > /tmp/pristine/client.go
    # overlay.json Replace-maps those two paths, and maps the two untracked probe_*_test.go to ""
    CC=clang go test -overlay=/tmp/pristine/overlay.json ./internal/cli/ \
      -run 'TestUnmeteredMarker|TestAttentionStatusClassification|TestAttentionBucket|TestStrainedFence|TestAttentionVocabularyMatchesFixture' -v

## 5. MUTATION: insert an `unmetered` rung ahead of `strained` in attentionStatus

Replace in the pristine copy:

    case live && strained(b):        ->    case live && unmeteredMarker(b) != "":
                                                   return "unmetered"
                                           case live && strained(b):

Result: `TestUnmeteredMarker` FAILS at `cloud_status_cmd_test.go:322` —
`the marker must not invent a rung: status = "unmetered", want ok`.
`TestAttentionVocabularyMatchesFixture` still PASSES — the closed-enum fixture guard does NOT cover a
status string escaping `attentionStatus`.

## 6. Go's bucket fails SAFE; the SPA's does not

    sed -n '/^func attentionBucket/,/^}/p' internal/cli/cloud_status_cmd.go   # default: "attention"
    git show origin/main:cloud/priv/static/app.js | sed -n '5295,5300p'       # 9 ranks, unreported=5
    git show origin/main:cloud/priv/static/__fixtures__/attention_order.json  # 8 states, no unreported
