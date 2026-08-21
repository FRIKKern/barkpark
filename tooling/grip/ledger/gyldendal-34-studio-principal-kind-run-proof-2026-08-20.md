# Re-derivation recipe — Gyldendal #34: the Studio flat→scoped funnel is principal-kind blind

Verifier: studio-34-run-proof · wave gyldendal-field-report-wave-2026-08-20 · 2026-08-20
Tree: primary checkout at 6f724edfd8; `git diff --stat 6f724edfd8 a07a0baa13 -- api/` is EMPTY,
so every result below is origin/main a07a0baa13 for api/.

## VERDICT

#34 is NOT "read denial masked as does-not-exist" (charter D8's framing). It is a SCOPE
MIS-RESOLUTION in the flat→scoped 302 funnel that fires for ACCOUNT (user_session) principals
only. A TOKEN principal resolves CORRECTLY. #34 does not belong to S1's token-tenancy family,
and neither the `:api` DeriveWorkspaceFromToken relocation nor D8's 403-error-shape chokepoint
would fix it.

## The mechanism (one argument, two call sites)

`BarkparkWeb.Studio.ScopeResolver.resolve_scope/2` takes the principal as its 2nd argument.
Both callers pass `conn.assigns[:api_token]`:

  api/lib/barkpark_web/controllers/studio_redirect_controller.ex:70   (also serves PageController)
  api/lib/barkpark_web/controllers/admin_studio_redirect_controller.ex:103

`OptionalSessionToken` assigns `:current_user` (NOT `:api_token`) for an account session
(api/lib/barkpark_web/plugs/optional_session_token.ex, the `user_from_session/1` arm), so the
argument is `nil` → `resolve_workspace(nil)` → `Tenancy.get_default_workspace()`
(scope_resolver.ex:80).

`Tenancy.list_workspaces_for/1` ALREADY has a working `%User{}` clause (tenancy.ex:832). The
fix exists and no caller reaches it — the M4 shape.

Second, independent site of the same blindness: `StudioChrome.open_scope_menu/1`
(api/lib/barkpark_web/studio_chrome.ex:310) builds the workspace SWITCHER from
`socket.assigns[:api_token] |> Tenancy.list_workspaces_for()` → `[]` for an account session →
no in-UI escape from the wrong workspace.

## Re-derive

    # 0. tree identity
    git diff --stat 6f724edfd8 a07a0baa13 -- api/          # empty == this checkout IS main for api/

    # 1. AssignDefaultScope is in SEVEN pipelines, NONE of them browser/studio
    cd api && awk 'BEGIN{p="(none)"} /^  pipeline :/{p=$0} /AssignDefaultScope\)|DeriveWorkspaceFromToken\)/{ if ($0 ~ /^ *plug\(/) print NR": "p"  ->  "$0 }' lib/barkpark_web/router.ex
    # → :api, :cycle_api, :scoped_media_mutate, :api_preview, :session_token_root,
    #   :media_mutate, :search_settings_admin.  Studio rides :browser / :scoped_browser /
    #   :shared_studio_browser / :soft_token — none carry it.

    # 2. the four reasons the notice can ever report (no :forbidden arm)
    sed -n '934,972p' lib/barkpark_web/live/studio/studio_live/shared.ex

    # 3. the run proofs (probe sources archived beside this file, see below)
    MIX_TEST_PARTITION=_s34 BARKPARK_TEST_POOL_SIZE=6 mix test <probe>.exs

## Probe sources

Two ExUnit probe files were run from OUTSIDE the repo (verifier carve-out: no repo test writes):
`<scratchpad>/s34/studio34_probe_test.exs` and `studio34_probe2_test.exs`. They are reproducible
from the recipe above: `ensure_default_scope!()`, a second workspace `gyl-b-<n>`, an account
session via `Accounts.register_user` + `create_user_session_token` + `create_membership(ws, user,
"admin", "user")` put in `Plug.Test.init_test_session(conn, %{"user_session" => raw})`, then
`get(conn, "/studio/production/post/doc-does-not-exist")` and read the `location` header.

## Measured results

    (a) ACCOUNT session, member of gyl-b-11555 ONLY, api_token=nil
        302 → /w/default/p/default/d/production/studio/post/doc-does-not-exist      ← WRONG
    (b) TOKEN principal, no membership in gyl-b-11779
        302 → /w/default/p/default/d/production/studio/post/doc-does-not-exist
    (b2) TOKEN principal, member of gyl-b-11299 ONLY
        302 → /w/gyl-b-11299/p/default/d/production/studio/post/doc-does-not-exist  ← CORRECT
    (c) rendered notice on the (wrong) Default studio:
        data-reason="unknown_node" for post/…, "not_found" for paper/…;
        the :not_found copy is "…It may have been deleted, or it may live in another workspace
        or project." — a TRUTHFUL answer about the Default workspace.
    (d) the SAME account session GETs /w/gyl-b-11971/p/default/d/production/studio/... → 200.
        There is no denial anywhere in the path.
    (e/H) the workspace switcher on the Default studio does not list gyl-b-* for that session.
    (F) list_workspaces_for(nil) = [] ; list_workspaces_for(%User{}) = ["gyl2-b-1156"]
    (G) resolve_scope(conn, conn.assigns[:api_token]) → default
        ScopeResolver.resolve_workspace(user) → "gyl2-b-292"   ← the correct answer, unreached

## Consequences for the wave

* The fix fixture MUST be an ACCOUNT (user_session) principal. A token fixture passes today
  and would certify nothing.
* Whether Gyldendal held an account or a token session is UNRESOLVED — the twin repo
  (~/Documents/GitHub/gyldendal-agency-barkpark) is not on this host and the five field papers
  carry no repro. If they held a TOKEN, #34 has a different cause and must be re-derived.
* Prior art, already CLOSED, same family, different site: `arpss-w10-bl-workspace-admin-bare-
  user-id-silent-false` (PR #12710) and `arpss-w10-bl-studiochrome-admin-default-workspace-
  scoping`. The ScopeResolver call sites were NOT covered by them.

## Gate baseline measured for this claim

    mix test test/barkpark_web/studio/       → 390 tests, 0 failures (9 excluded)
    mix test test/barkpark_web/live/studio/  → 1618 tests, 0 failures
