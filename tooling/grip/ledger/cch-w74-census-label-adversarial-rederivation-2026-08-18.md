<!-- doc-tier: cold | canonical-for: cch-w74-census-label-adversarial-rederivation | budget: 1200tok -->
# cch-w74 — census-label adversarial re-derivation recipes (2026-08-18)

Verifier: census-label-adversarial. Census at PR #12067 head 7ef99310c9623e313d2456f67a95525ed316a684
(`git ls-remote origin loop-epic/the-wire-vs-reader-census-guard-every-ty-0-r`). All app.js/router.ex
reads are `git show origin/main:<path>` — never the worktree.

## Row counts at head

    git show 7ef99310c9623e313d2456f67a95525ed316a684:cloud/test/barkpark_cloud/console_reader_census_test.exs | grep -c 'code: "'   # 137
    git show 7ef99310c9623e313d2456f67a95525ed316a684:cloud/test/barkpark_cloud/console_reader_census_test.exs | grep -c 'READER OWED' # 4

## The friendly() ladder (decides every fallback-covered ruling)

    git show origin/main:cloud/priv/static/app.js | sed -n '366,448p'
    # rungs: nested-unwrap → forbidden evidence → ERRORS[key] → detailS (PLURAL map) → D855 singular-detail
    # rung fenced to 4 slugs AND typeof detail === "string" → fallback || humanized slug.

## Mislabeled rows (relabel; disposition unchanged unless noted)

- prebuilt_not_enabled + unknown_source are NOT console-reachable: both key on the REQUEST body
  (`source = conn.body_params["source"] || "box-build"`), and both console deploy callers send no source:
      git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '12109,12140p'
      git show origin/main:cloud/priv/static/app.js | grep -n 'api("POST", "/v1/sites/.*deploy"' # 14401 {} · 14565 {git_ref}
      git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex | grep -n '@sources'  # box-build prebuilt
  unknown_source's reason also mis-derives the mechanism ("deploy source column… data drift" — it is the body param).
- email_mismatch HAS a status-read reader (row says fallback renders — false):
      git show origin/main:cloud/priv/static/app.js | sed -n '14774,14782p'   # inviteTerminalFrom: 403 → "wrong_account"
      git show origin/main:cloud/priv/static/app.js | sed -n '14835,14841p'   # the wrong-account card copy
  403 is unique on POST /v1/invitations/accept (router.ex 5662 is its only 403 arm).
- invalid_current_password HAS a status-read reader (row says fallback renders — false), with a conflation hazard:
      git show origin/main:cloud/priv/static/app.js | sed -n '1706,1717p'
      # r.status === 401 ? "Current password is wrong." : friendly(...) — noBounce:true, so an
      # expired-session 401 (Auth.require_user → unauthorized) paints the same sentence. Flip or fix by
      # keying on data.error === "invalid_current_password".
- invalid_settings: "Console-reachable" overstates — the only console PATCH /v1/sites/:id caller is the
  theme select submitting members of SITE_THEMES; reaching invalid_settings needs client/server list drift.
      git show origin/main:cloud/priv/static/app.js | grep -n 'api("PATCH", "/v1/sites/'   # 12458 only
      git show origin/main:cloud/priv/static/app.js | sed -n '12541,12550p'                # siteThemeFailureCopy → faultCopy
  Mechanics VERIFIED: emit ships detail-singular MAP (router.ex 7075 `detail: errors(cs)`); plural-details
  rung and string-fenced D855 rung both skip → the designed fallback truly paints.

## Transience-lie verdicts (charter D875's own standard: retry-verb copy on a permanent-until-acted state)

- no_content_binding: console-reachable (Deploy button on any site; CLI-created unbound sites exist —
  dataset optional server-side) and paints runDeploy's "Please try again." → MEASURED LIE, same class the
  charter already ruled for repo_not_in_installation in D875. "Honest but unspecific" does not stand.
- invalid_name: reachable (free-text #new-gh-name, admin-gated) and paints "Please try again." for a
  deterministically invalid name → lie (parity gap: repo_exists 409 got "Pick a different name").
  Census site-cite "(vercel_reason mapping)" is imprecise — it is a local guard, router.ex 4867.

## STATUS-READ rows both STAND

- build_in_progress: .dep-promote → wireDeployActions (app.js 13310) → confirmPromote → runPromote;
  promoteFailure 409 arm; single 409 emitter (router.ex 12342, inside promote_deployment).
- teardown_failed: confirmSiteDelete (#site-delete, app.js 12441) → siteDeleteFailureCopy arms 5/6/7
  (422-timeout regex, 422 detail-relay, 502); stray ≥500 lands the hedged crash arm.

## D874 retry verb — DROP IT

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '12207,12216p'  # console emit: "Retry the deploy" (true here)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '13948,13962p'  # CLI twin: "MINT A NEW DEPLOYMENT, NOT RE-POST"
  Slug-invariant safe verb: "start a fresh deploy" — true at both sites; bare "retry"/"try again" invites
  the already_uploaded trap at the artifact site.
