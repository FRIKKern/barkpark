# cch w17 — gate + fence re-derivation recipes (2026-08-01)

Tree under test: `origin/main` = 97a581f6d, driven from a detached worktree
(`git worktree add --detach <scratch> origin/main`) because the primary
checkout is 265 commits BEHIND origin/main and 48 ahead — its files are L3.

## 1. Console gate self-test (144 assertions)
    bash scripts/console-path-escape-check.sh --selftest 2>&1 | tail -3
    # -> "144 passed, 0 failed", rc 0

## 2. The ten gate() fixtures and the five upstream results
    grep -c '^gate ' scripts/console-path-escape-check.test.sh      # -> 10
    grep -n 'needs:' .github/workflows/console-harness.yml
    # -> console-gate needs [changes, console-unit, cssom-parity, tier-floor-render, path-escape]

## 3. Whole console-unit lane, green on main
    node --check cloud/priv/static/app.js                                    # rc 0
    node --test  cloud/priv/static/__app.test.mjs                            # 758/758
    node         cloud/priv/static/__preview__/smoke.mjs                     # 99 scenarios
    node --test  cloud/priv/static/__preview__/seal-predicate.test.mjs       # 49/49
    node         cloud/priv/static/__preview__/breakpoint-sweep.mjs          # rc 0
    node --test  cloud/priv/static/__preview__/breakpoint-sweep.test.mjs     # 51/51
    node         cloud/priv/static/__css_check.mjs                           # 0 errors
    bash         scripts/console-path-escape-check.sh                        # 10 reads, OK

## 4. cssom-parity / the D158 baseline recipe (real Chrome, 1.9s wall)
    node cloud/priv/static/__preview__/cssom-parity.mjs
    # -> authored rule heads 1253 (baseline 1253), MISSES 0, PARITY PASS
    cat   cloud/priv/static/__preview__/cssom-heads.baseline | tail -1   # 1253
    grep -cE '^[0-9]+$' cloud/priv/static/__preview__/cssom-heads.baseline  # 1

## 5. The fence — Console gate is NOT live-required
    gh api repos/:owner/:repo/branches/main/protection/required_status_checks
    # live contexts == ["Elixir gate","PR references an active task"], strict=false
    # .github/required-checks.json commits FOUR incl. "Console gate" — known human
    # gate cch-hg-register-cssom-required-check (charter D98/D134).

## 6. PR #6028 vs s4 — the merge-order proof
    gh pr view 6028 --json state,isDraft,mergeable,mergeStateStatus,updatedAt,baseRefOid
    # OPEN, isDraft false, CONFLICTING/DIRTY, updated 2026-07-31T04:24:49Z,
    # base 3304236d0 which origin/main is 106 commits ahead of.
    # Three-way merge (base=3304236d0, ours=PR head 360b67590, theirs=origin/main):
    for f in app.js __app.test.mjs; do git merge-file -p --diff3 $PR/$f $BASE/$f $MAIN/$f; done
    # app.js -> 1 conflict, in the /v1/me repaint seam (main app.js:12356-12366).
    # __app.test.mjs, router.ex and all non-cloud files -> 0 conflicts.
    # #6028's app.js edits on MAIN numbering: 4748, 5633, 5669, 5785, 12356-12366, 18710
    # s4's anchors on MAIN numbering:         7276, 7534, 9497, 9713/9715/9718/9721
    # -> textually disjoint. Either order merges; s4 first is strictly better.

## 7. s8's before-number is STALE (refutation)
    node cloud/priv/static/__preview__/breakpoint-sweep.mjs --render \
      --widths 320,375,619,720,899,900,901,1200,1700 --cell billing-trial
    # -> "56 measured defects (Q1 4 · Q2 52 · Q3 0) — exit 1"
    # s8's criterion 1 asserts the BEFORE state is 28 (Q1 2 · Q2 26). Exactly double,
    # consistent with wave-16 s2's theme axis rendering 2 cells per width.
    node cloud/priv/static/__preview__/breakpoint-sweep.mjs --render --widths 901 --cell billing-trial
    # -> "clean across 2 cells — exit 0"  (the tier-floor-render job is GREEN on main)
