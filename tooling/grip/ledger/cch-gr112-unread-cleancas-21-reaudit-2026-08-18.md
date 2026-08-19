<!-- doc-tier: cold | canonical-for: none (ledger recipe row) | budget: 1200tok -->
# GR112 unread clean-CAS 21-row re-audit — re-derivation recipe (2026-08-18)

Discharges the seal's one un-run promise: "21 clean-CAS children are sealed on
evidence nobody read." Runs GR112's frozen material-failure test on each of the 21
rows enumerated BY NAME in charter GR123 (git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md, ~line 597).

MATERIAL FAILURE (frozen, GR112 line 148): cited artifact absent on origin/main
OR criterion's user-visible claim false at origin/main today. NOT material:
line-drift, unmet "PR merged" whose work is on main, supersession close.

RESULT: 0 material failures across all 21 (not a sample — full enumeration).

## Re-derive

    cd /Volumes/SATECHI/github/barkpark
    ROWS=(gr-backlog-email-fleet-mapping gr-backlog-role-vocabulary gr-backlog-shoot-matrix-budget \
      gr-backlog-wave-exhaust gr-p2-home-triage gr-p2-launch-theater gr-p3-hygiene-guard \
      gr-p3-timeline-grammar gr-p3-webhooks gr-p4-billing gr-p4-members-env gr-p5-honesty-batch-1 \
      gr-p5-operator-routes gr-w1-charter-archive-pr gr-w1-cloudchrome-bridge gr-w1-css-check-detector \
      gr-w1-operator-me-flag gr-w1-shell gr-w1-styleguide-port gr-w1-token-ramps task-7836903b7ea83111)
    # all done, parent=task-47bc4168392dec17; bp task get <id> -o json | jq .doc.content.acceptance_criteria

## SHA ancestry (all 18 cited PRs are ancestors of origin/main)

    git merge-base --is-ancestor 7a43e5847 origin/main            # role-vocabulary, shoot-matrix (#4391)
    git merge-base --is-ancestor 5cac4ffedbf2334fe6b94ec3b7c3a2881d86c7e6 origin/main  # home-triage #4256
    git merge-base --is-ancestor 401e250c7488086bc052e65586c544cdde2a3c99 origin/main  # launch-theater #4254
    git merge-base --is-ancestor 09735e96baab4f143991fa81f8ba3091d68ba97f origin/main  # #4271 (hygiene/timeline/webhooks)
    git merge-base --is-ancestor 444f07317719225d451f0673e49fa8c7fa37c7ad origin/main  # #4304 (billing/members-env)
    git merge-base --is-ancestor 301e035d8 origin/main            # honesty-batch #4433
    git merge-base --is-ancestor 567bf6e396267b7d71b0ed142040971bb30761d1 origin/main  # operator-routes #4389
    git merge-base --is-ancestor 76122e55a6c93543bdcf80e26b09154004d4e765 origin/main  # charter-archive #4230
    git merge-base --is-ancestor d9cfdfec2288380a2edfa3ad57f3efc0eb7ff3a0 origin/main  # cloudchrome #4236
    git merge-base --is-ancestor 3c39c32b0ef587ee99cb892a0c1f2b9970ef0b31 origin/main  # css-detector #4231
    git merge-base --is-ancestor 019aae88a4636515bf8be19b3785db0cda00c0fe origin/main  # operator-me-flag #4234
    git merge-base --is-ancestor 23e2bd3e4a72ab8780f8a187d9e986ff83221974 origin/main  # shell #4238
    git merge-base --is-ancestor 9a12ba011dc508a603845e382ba51c03ff77b98f origin/main  # styleguide #4237
    git merge-base --is-ancestor e147e6c2f8fe5e3156f05678a21ddc7316289801 origin/main  # token-ramps #4233
    # NOTE: the ledger evidence string for token-ramps criterion-6 is the correct SHA
    # e147e6c2...; a synced_rev md5 (e7f782a0b69224ae229dd03fac26e881) sits in the github
    # block and is NOT a git SHA — do not feed it to merge-base.

## User-visible symbol on origin/main (one per row)

    M=origin/main
    git show ${M}:docs/contracts/tenancy.md            | grep -n 'Two role axes'      # role-vocabulary
    git show ${M}:cloud/priv/static/__preview__/shoot.sh | grep -nE 'SCEN|ACCENT'      # shoot-matrix
    git show ${M}:cloud/priv/static/app.js | grep -nE 'loadOverview|overviewSubline'   # home-triage
    git show ${M}:cloud/priv/static/app.js | grep -nE 'theaterPriceModel|newStepsHtml' # launch-theater
    git show ${M}:cloud/priv/static/app.css | grep -c 'var(--primary-soft)'            # =0 (retired)
    git show ${M}:cloud/priv/static/__css_check.mjs | grep -niE 'swallow|E9'           # hygiene-guard + task-7836903b
    git show ${M}:cloud/priv/static/app.js | grep -n 'coalesceEntries'                 # timeline
    git show ${M}:cloud/priv/static/app.js | sed -n '10276,10300p' | grep -c consecutive_failures  # =0 count-free banner (webhooks)
    git show ${M}:cloud/priv/static/app.js | grep -nE 'billingIsOwner|readOnlyPlanCardHtml'  # billing
    git show ${M}:cloud/priv/static/app.js | grep -nE 'membersPanelHtml|envVarRowHtml' # members-env
    git show ${M}:cloud/lib/barkpark_cloud/web/router.ex | grep -n retry_after         # honesty-batch
    git show ${M}:cloud/lib/barkpark_cloud/web/auth.ex   | grep -n 'def require_platform_operator'  # operator-routes
    git ls-tree -r ${M} --name-only | grep -c 'design/handover/ui-review-9/'           # =65 (>=59) charter-archive
    git show ${M}:design/tokens.json | grep -c cloudChrome                             # cloudchrome
    git show ${M}:cloud/priv/static/__css_check.mjs | grep -cE E6                       # css-detector
    git show ${M}:cloud/lib/barkpark_cloud/web/router.ex | grep -nE 'platform_operator:|max-age=31536000'  # operator-me-flag
    git show ${M}:cloud/priv/static/index.html | grep -cE 'nav-layer|ws-switch'        # shell
    git show ${M}:design/emit.mjs | grep -n styleguideSwatches                         # styleguide
    git ls-tree ${M} --name-only design/themes/iris.json                               # token-ramps (iris ramp)
    git grep -L html_body ${M} -- cloud/lib  # html_body appears NOWHERE; text_body in 3 modules -> email-fleet plain-text TRUE

## Two code-less rows (no material artifact, no false claim = PASS)

- gr-backlog-wave-exhaust: branch/worktree cleanup ops; its named merged PRs
  (#4236/#4238/#4237/#4277/#4271) are all ancestors. Nothing false on main.
- gr-backlog-email-fleet-mapping: GR46 decision-only close; the plain-text claim
  is TRUE on main (html_body absent, text_body present).
