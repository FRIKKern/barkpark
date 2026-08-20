# cch-w77 V6 — Bucket-A stragglers per-criterion adjudication (#9956/#10085/#10154/#10155 + #10006)

Wave 77 verify. Re-derivation recipes only. Authority `origin/main` @ `8dadc9b516eb47caa0b1bf752d95b6da69bae0f0`
(re-derive: `git rev-parse origin/main`). Run from repo root.

## Verdict in one line

The "supersession inferred from the test/census FILE existing on main" hypothesis is REFUTED per-criterion.
For ALL FIVE PRs the sole/primary unmet criterion is MERGE-GATED, the PR head is NOT an ancestor of
origin/main, and the SPECIFIC build deliverable is ABSENT from origin/main. None is superseded; none is
close-as-done eligible. #10006 must stay OPEN. Correct category = BUILT-ON-BRANCH-UNMERGED (blocker=merge),
NOT "genuinely-unbuilt inherited GUI-remake backlog".

## PR -> task -> unmet criterion -> is it satisfied on main?

| PR | task (lifecycle) | met/total | unmet criteria | on main? |
|---|---|---|---|---|
| #9956 | cch-w38-s2-no-team-stops-being-a-422 (open) | 9/10 | [9] merge-gated | NO |
| #10085 | cch-w40-s3-...-2d-stops-freezing-a-live-defect (open) | 9/10 | merge-gated | NO |
| #10154 | cch-w42-s2-role-ladder-census-derives-its-domain (open) | 8/10 | [8] PR-body, [9] merge | NO |
| #10155 | cch-w42-s4-main-push-gate-failures-find-a-human (open) | 7/9 | [7] PR-body, [8] merge | NO |
| #10006 | cch-w39-s2-the-account-modal-stops-stating-a-2fa-state-it-never-read (open) | 10/11 | [10] merge | NO |

Re-derive met/total + unmet flags:

    bp task get "cch-w38-s2-no-team-stops-being-a-422" -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['criteria_progress']);[print(i,'MET' if c.get('met') else 'UNMET',c['criterion'][:80]) for i,c in enumerate(d['content']['acceptance_criteria'])]"
    # repeat for the other four slugs (cch-w42-s2-role-ladder-census-derives-its-domain, cch-w42-s4-main-push-gate-failures-find-a-human, cch-w39-s2-the-account-modal-stops-stating-a-2fa-state-it-never-read)

## Ancestry (close-as-done hard filter #1 — FAILS for all five)

    for pr in 9956 10085 10154 10155 10006; do sha=$(gh pr view $pr --json headRefOid -q .headRefOid); git merge-base --is-ancestor "$sha" origin/main && echo "$pr ANCESTOR" || echo "$pr NOT-ancestor"; done
    # all five: NOT-ancestor

## Per-PR content proof: the SPECIFIC deliverable is ABSENT from origin/main

    # #9956 (cch-w38-s2) — auth.ex primary-team gates STILL emit 422 no_team (fix demands 403):
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'json_halt(conn, 422, %{error: "no_team"})'
    # -> 422:  and 453:  present. The 403 {reason:"no_team", scope:"primary_team"} flip is NOT on main.
    # (the 403 no_team pins in router_ability_matrix_test.exs on main are the cch-w37-s3 gate_role scope:"team" arm — a DIFFERENT gate.)

    # #10085 (cch-w40-s3) — census mjs exists, fixture control does NOT:
    git cat-file -e origin/main:cloud/priv/static/__binding_census.add.fixture.js || echo "fixture ABSENT"
    git show origin/main:cloud/priv/static/__binding_census.mjs | grep -c 'add-check\|remove-check\|must-flag'   # -> 0
    git show origin/main:.github/workflows/console-harness.yml | grep -c 'add-check\|remove-check'                # -> 0

    # #10154 (cch-w42-s2) — no accessors, full_role_domain still the pre-fix single-ladder form:
    git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex | grep -c 'def admin_roles'           # -> 0
    git show origin/main:cloud/lib/barkpark_cloud/accounts/team_membership.ex | grep -c 'def ranked_roles' # -> 0
    git show origin/main:cloud/test/barkpark_cloud/accounts/role_agreement_census_test.exs | grep -n 'defp full_role_domain'
    # -> "defp full_role_domain, do: TeamMembership.roles() ++ [nil] ++ @off_ladder"  (NOT the ranked_roles++admin_roles union)

    # #10155 (cch-w42-s4) — reporter job ABSENT from both workflows (the shell script pre-exists; the WIRING is the deliverable):
    git show origin/main:.github/workflows/cloud.yml            | grep -c 'report-main-failure'  # -> 0
    git show origin/main:.github/workflows/console-harness.yml  | grep -c 'report-main-failure'  # -> 0

    # #10006 (cch-w39-s2) — badge still boolean, no phase fn, no null-guard:
    git show origin/main:cloud/priv/static/app.js | grep -n 'function accountTwoFactorBadgeHtml(enabled)'  # boolean signature = pre-fix
    git show origin/main:cloud/priv/static/app.js | grep -c 'accountTwoFactorPhase\|twoFactorEnabled: me.user'  # -> 0

## Honesty-relevance split (a Decide input — not all five are console-honesty lies)

- LIVE claim/reality lie, built-on-branch-unmerged: #9956 (teamless user told "domain syntax wrong"),
  #10006 (2FA state stated from an unread /v1/me envelope). Real honesty fixes; #9956 is OUT of the
  password-401 fence (auth.ex + app.js:6971 attachDomain, not submitPasswordChange).
- LATENT drift guard, not a live lie: #10154 (its own criterion 4: predicates AGREE on main today).
- Test/census infra guard: #10085 (fixture control over the binding census).
- CI/OPS reliability, inherited ops backlog: #10155 (post-merge main failure alerting).

## Disposition for Decide

Do NOT close any as superseded (repeats the batch-close-by-heuristic sin: the FILE on main is not the FIX
on main). Each is mergeable-work stranded at merge, mutation-proven on-branch per its criteria. Choose per
row: MERGE (like the #12158 survivor) or RE-HOME to the successor with the "built, unmerged" note — never
fold into the "genuinely-unbuilt GUI-remake backlog" bucket, and never fake-close. #10006 stays OPEN.
