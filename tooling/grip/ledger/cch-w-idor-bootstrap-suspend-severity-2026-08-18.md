# Re-derivation: /bootstrap suspended-box gap — payload severity + test-absence

Wave: api-read-path-security-sweep IDOR/ownership audit (cloud instance-API).
Verifier assignment: bootstrap-severity. Read via `git show origin/main:` only.

## Claim 1 — /bootstrap is ownership-enforced (NOT an IDOR) but has NO suspended-box refusal

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4309,4340p'

Route `get "/v1/barkparks/:id/bootstrap"` (line 4309): resolves via
`Registry.get_barkpark(id)` then matches `%Barkpark{team_id: tid} = bp when tid == team.id`
(team = conn.assigns.current_team) → wrong team / unknown id fall to `_ -> 404 not_found`.
Team-ownership ENFORCED. But there is NO `suspended: true` clause above the reveal —
it goes straight to `Registry.reveal_bootstrap(bp)`.

Contrast /credentials (line 2762): has `%Barkpark{team_id: tid, suspended: true} when tid == team.id -> json(conn, 409, %{error: "suspended"})`
placed ABOVE the reveal (cch-w54-s2). Same for studio-link (2830, 409 @2875) and app-token (2925, 409 @2962).

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -nE 'get "/v1/barkparks/:id/(credentials|bootstrap)"|error: "suspended"'
    # 2762 credentials | 2785,2875,2962 suspended clauses | 4309 bootstrap (NO suspended clause)

## Claim 2 — the bootstrap payload's strongest secret is a READ-ONLY public-read token, no admin/write material

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '3593,3610p'   # reveal_bootstrap/1
    git show origin/main:internal/bootstrap/bootstrap.go | sed -n '/func resolveEnv/,/^}/p'

reveal_bootstrap returns `%{template, workspace, project, dataset, read_token, env}`.
env sources (resolveEnv switch): SourceAPIURL (scoped base URL), SourceReadToken (the
workspace-bound public-read token, label "bootstrap-public-read"), SourceDataset,
SourceWorkspace, SourceProject, SourceLiteral, SourceWebhookSecret (ISR-revalidation HMAC).
NO admin token, NO write-capable token in env. The read_token is read-only by scope;
the admin bearer is revealed only by the SEPARATE /credentials route.
=> Severity = MODERATE-to-LOW read-only intra-team suspension inconsistency, NOT an IDOR,
   NOT an admin/write leak. This is exactly why cch-w54-s2 scoped bootstrap OUT: its docstring
   names "the three admin-credential-backed routes — studio-link, app-token, credentials".

## Claim 3 — NO test pins a suspended-box 409 on /bootstrap; credentials/studio-link/app-token each DO

    grep -niE 'suspend' cloud/test/barkpark_cloud/bootstrap_template_test.exs   # exit 1, zero matches
    cd cloud && mix test test/barkpark_cloud/bootstrap_template_test.exs        # 14 tests, 0 failures (no suspend case)
    for f in $(grep -rlnE 'bootstrap' cloud/test/barkpark_cloud/web/); do echo "$f: $(grep -cE 'suspend' $f)"; done
    # only router_site_url_suspended_test.exs matches (site-url route, not /bootstrap)

    grep -nE 'credentials|suspend|409' cloud/test/barkpark_cloud/web/router_studio_link_test.exs
    # cch-w54-s2 block asserts suspended->409 for studio-link (250), app-token (276), credentials (290)

Conclusion: gap is REAL and UNTESTED. Ruling input for Decide — small fail-closed inline fix
(mirror credentials 2783 `suspended: true` clause + reds-on-revert test) is defensible; severity
is low enough (read-only token + build env, no admin material) that filing as a child is also valid.
Not an IDOR — belongs to the intra-team suspension-consistency class, adjacent to the IDOR capstone.
