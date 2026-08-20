# cch-w36 — the /v1/audit 403 shape, re-derived (2026-08-06)

Verifier `audit-403-shape`, wave 36. Base: `origin/main` = `070c7584b820745e1ac8377ca6926edef6d2f257`.
Every row below is a command, not a claim. Run them from a checkout AT that sha
(the primary checkout was 490 behind when this was written — do not run these
against a stale worktree).

## R1 — the exhibit's endpoint DOES carry evidence (fix is client-only)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'get "/v1/audit"'
    #   1907
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '288,305p'
    #   require_primary_team_admin -> forbidden(conn, required: "admin", scope: "primary_team")

Live body, driven through Plug.Test (probe kept out of the repo, in the
verifier scratchpad):

    cd <wt@070c7584b>/cloud && CC=clang mix test <scratch>/audit_403_shape_probe_test.exs
    # PROBE1 status=403 body={"error":"forbidden","scope":"primary_team","required":"admin"}

## R2 — /v1/audit is NOT one of the 12 bare literals

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n '403, %{error: "forbidden"}'
    # 2028 2192 4272 4308 4330 4617 4633 4846 4879 5025 8055 8255   (1907 absent)
    # 8055 = the go_live inline team-admin cond; 8255 = resurrect's inline team-admin cond.

## R3 — the pin already exists and is full-map equality

    cd <wt@070c7584b>/cloud && CC=clang mix test test/barkpark_cloud/web/router_ability_matrix_test.exs
    # 47 tests, 0 failures — incl. "require_primary_team_admin names admin on the
    # primary team (the audit-trail exhibit)" at router_ability_matrix_test.exs:380

## R4 — "primary" IS a misnomer; the scope STRING is wrong under the team switcher

    # PROBE2b (owner of primary, member of second, x-barkpark-team: <second>)
    #   status=403 body={"error":"forbidden","scope":"primary_team","required":"admin"}
    # PROBE3b (member of primary, ADMIN of second, x-barkpark-team: <second>)
    #   status=200
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '116,130p'   # resolve_team

The gate reads `conn.assigns.current_team`, which `require_user/2` fills from
`resolve_team/2` — header-honoring. So `scope: "primary_team"` names a team that
may not be the refusing team. Any rendered sentence must NOT say "primary".

## R5 — the client discards the evidence

    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    grep -n 'data\.required\|data\.scope' /tmp/app_main.js       # (no hits)
    grep -n 'esc(friendly(r.data))' /tmp/app_main.js             # 5530 5968 10400 14023
    grep -n 'readFailureCopy(' /tmp/app_main.js                  # 289 (def) 3779 8010
    sed -n '224,237p' /tmp/app_main.js                           # friendly(): ERRORS -> details -> fallback
    sed -n '207p'    /tmp/app_main.js                            # forbidden: "Only the team owner can manage billing."
    sed -n '14015,14026p' /tmp/app_main.js                       # loadActivity -> esc(friendly(r.data))

STALE ANCHORS (do not inherit): the open row
`cch-w34-bl-bare-friendly-renders-billing-copy-on-four-reads` names 5376/5814/
10236/13882; the wave-36 digest names 5461/5899/10321/13944. Both wrong at
070c7584b. Truth = 5530/5968/10400/14023. There is no fifth bare site; line
12079 is `esc(friendly(r.data, "Couldn't load your repositories."))`, i.e. it
carries a fallback that the curated ERRORS map still beats.
