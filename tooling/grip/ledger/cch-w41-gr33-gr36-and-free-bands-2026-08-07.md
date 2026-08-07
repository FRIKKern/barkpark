# cch-w41 verifier — GR33/GR36 anti-ghost authority + the four "free" app.js bands

Baseline: `origin/main` = `8ae30b34bfc858184f6f1702a2dce57843903987` (2026-08-07).

## A. Which rule states the anti-ghost law

    git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md | grep -n "ghost"
    # 49 (GR33 PLAIN-MEMBER LAW) and 107 (GR82, unrelated "manufactured this ghost"). GR36 (line 52) = 0.
    git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md | sed -n '52,58p' | grep -c ghost   # 0
    git show origin/main:cloud/priv/static/__preview__/smoke.mjs | sed -n '1951p'
    # "// … but with ZERO write affordances — never a disabled ghost (GR36)."

VERDICT: the *phrase* is GR33-only. GR36 states the no-rendered-affordance duty
INDEPENDENTLY but per page and in different words (G-01 "no rendered CTA";
G-02 "zero connect/disconnect affordances"). Neither rule's population contains
the instance-detail lifecycle rail, so D428's carve-out is legally clean under
both; smoke.mjs:1951's citation is right in effect, wrong in wording.

## B. Free-band re-derivation, TRUE main coordinates

    # per-PR OWN edits (never `git diff origin/main pr/N` — that folds in main-ahead noise)
    for n in 10088 10054 10085 10087 10083 10005 10006 9955 9956 9887; do
      mb=$(git merge-base origin/main refs/remotes/pr/$n)
      git diff -U0 $mb refs/remotes/pr/$n -- cloud/priv/static/app.js | grep '^@@'
    done
    git show origin/main:cloud/priv/static/app.js | grep -n \
      "function providerCanWrite\|function canManageOnboarding\|function billingCanManage\|function assignableRoles"
    # 2378 / 6045 / 13406 / 18004

app.js editors among ALL open PRs: 10083, 10005, 10006, 9955 only.
10088 / 10054 / 10085 / 10087 / 9956 / 9887 edit app.js ZERO bytes.
No open PR edits any of the four band definitions. Nearest claims:
providerCanWrite's CONSUMER `renderProviderPage` (main ~2667) IS rewritten by
#10005; billingCanManage's consumer `renderBilling` (main ~13447) IS rewritten
by #10005.

## C. Census collision (refutes "merges clean")

    git merge-tree --write-tree refs/remotes/pr/9955 refs/remotes/pr/10005; echo RC=$?
    # RC=1, CONFLICT (content) in cloud/priv/static/__preview__/breakpoint-sweep.test.mjs
    # scenarios.mjs auto-merges to 98 blocks (both `panel-overview-member` and
    # `billing-me-unreadable` land) while BOTH sides of the conflict assert 105.

`panel-overview-member` (D432's rail member fixture) is ABSENT from origin/main
and present ONLY in #9955.
