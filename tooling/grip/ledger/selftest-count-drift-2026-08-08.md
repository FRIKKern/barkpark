# selftest-count-drift — re-derivation recipes (wave 21 verify)

Question asked: "what removed the three assertion rows between #10607 and today?"
Answer: **nothing did.** The MUST-RUN recipe itself removed them, by extracting only
`deploy/` from the archive. Three self-test rows are guarded by
`if [ -f "$(dirname $SELF)/../api/lib/barkpark/sites/deploy_runner.ex" ]`
(static engine `site-deploy.sh:1544-1550`, node engine sibling), and that guard
prints **no SKIP banner** and still reports PASS.

## R1 — reproduce the drift (deploy-only archive → 320/176)

    cd /Volumes/SATECHI/github/barkpark
    S=$(mktemp -d); git archive origin/main deploy | tar -x -C $S
    bash $S/deploy/site-deploy.sh --self-test | tail -3        # 320/320 PASS
    bash $S/deploy/site-deploy-node.sh --self-test | tail -3   # 176/176 PASS

## R2 — dissolve the drift (add the one guarded file → 322/177, #10607's numbers)

    F=$(mktemp -d)
    git archive origin/main deploy api/lib/barkpark/sites/deploy_runner.ex | tar -x -C $F
    bash $F/deploy/site-deploy.sh --self-test | tail -3        # 322/322 PASS
    bash $F/deploy/site-deploy-node.sh --self-test | tail -3   # 177/177 PASS

## R3 — name the three rows programmatically (executed vs. authored)

    bash $S/deploy/site-deploy.sh --self-test 2>&1 \
      | grep -E "^  (ok|FAIL)" | sed -E 's/^  (ok|FAIL) +- //' | sort -u > /tmp/exec
    grep -oE '^[[:space:]]*check "[^"]*"' $S/deploy/site-deploy.sh \
      | sed -E 's/^[[:space:]]*check "//; s/"$//' | sort -u > /tmp/src
    comm -13 /tmp/exec /tmp/src
    # -> "…and that whitelist is still the six this engine folds"
    # -> "DeployRunner's @stage_names still has no ROUTE arm (the report cannot flip a verdict)"
    # same recipe on site-deploy-node.sh -> the node sibling row (1)

## R4 — the guard CAN fail (mutate the file it guards)

    G=$(mktemp -d)
    git archive origin/main deploy api/lib/barkpark/sites/deploy_runner.ex | tar -x -C $G
    perl -pi -e 's/\@stage_names ~w\(PLAN BUILD STAGE HEALTH SWITCH RETIRE\)/\@stage_names ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE ROUTE)/' \
      $G/api/lib/barkpark/sites/deploy_runner.ex
    bash $G/deploy/site-deploy.sh --self-test | tail -3        # 320/322 FAILED (2)

## R5 — the guard VANISHES silently (delete the file it guards)

    H=$(mktemp -d)
    git archive origin/main deploy api/lib/barkpark/sites/deploy_runner.ex | tar -x -C $H
    rm $H/api/lib/barkpark/sites/deploy_runner.ex
    bash $H/deploy/site-deploy.sh --self-test | tail -3        # 320/320 PASS  <-- exit 0, no SKIP
    # Contrast: the python3/curl/flock blocks DO print "[selftest] SKIP …" and are
    # hard-failed in CI by BARKPARK_SELFTEST_REQUIRE_E2E=1. This guard is in neither set.

## R6 — the guard rides the wrong path filter

    git show origin/main:.github/workflows/deploy-harnesses.yml | sed -n '3,8p'
    # on: pull_request: paths: ["deploy/**", ".github/workflows/deploy-harnesses.yml"]
    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts'
    # ["Elixir gate","PR references an active task","Cloud gate","Console gate"]  <-- not "Deploy harnesses"
    git grep -n "stage_names" origin/main -- api/test   # ZERO hits: no Elixir-side twin

## R7 — #10607's mutation claims, independently re-run (all at 322/177)

    # exact-string mutator (perl mangles `$)` into the GID variable — do not use perl here)
    python3 - <path> bare|space   # see scratchpad/mut.py; replaces site_route_marker_re/0 body
    #  bare   static : 310/322 FAILED (12)   [ = commit's 306/316 (10) + the 2 new delimiter rows ]
    #  bare   node   : 170/177 FAILED (7)    [ commit claimed 170/177 (7) — EXACT MATCH ]
    #  space  static : 320/322 FAILED (2)    [ exactly the two hand-edited-delimiter rows — EXACT MATCH ]
    #  space  node   : 177/177 PASS          [ NO node row distinguishes [^a-z0-9-] from [[:space:]] ]
