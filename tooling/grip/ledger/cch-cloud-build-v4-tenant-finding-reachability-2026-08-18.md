<!-- grip-ledger re-derivation recipe | wave: bp-cloud-build-wave-2026-08-18 | assignment: V4-tenant-finding-reachability -->

# V4 — search tenant-finding reachability (fail-closed re-derivation)

Authority note: local checkout was BEHIND (`a6535504`); origin/main tip = `41b16d78`.
ALL reads below are `git show origin/main:...` — authoritative for the merge-gate.

## Claim 1 — flat insights/synonym-write routes lack DeriveWorkspaceFromToken and the write guard

    cd api
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1972,1982p'
    # → scope "/v1/data" pipe_through([:api, :require_admin]); insights, synonyms GET/POST/promote/DELETE
    git show origin/main:api/lib/barkpark_web/router.ex | awk '/pipeline :api do/{f=1} f{print} /^  end/{if(f)exit}'
    # → :api runs AssignDefaultScope, NO DeriveWorkspaceFromToken  → current_workspace = Default for every caller
    git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | grep -n 'token_workspace_id\|nil_workspace_write_error'
    # → guard defs at 298/300/467/477 but INVOKED ONLY in update_search_settings (settings PUT, the FIXED search_settings_admin pipeline)
    # create_search_synonym(252)/promote(262)/delete(313)/search_insights(219) thread workspace_id(conn) = Default. No fail-closed.

## Claim 2 — reachability: [:api, :require_admin] passes a WORKSPACE-BOUND non-super admin token (NOT super-only)

    git show origin/main:api/lib/barkpark_web/plugs/require_admin.ex | grep -n 'has_permission'
    # → Auth.has_permission?(token, "admin")   (no super/platform/workspace check)
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '810,812p'
    # → def has_permission?(token, permission), do: permission in (token.permissions || [])
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '291,320p'
    # → create_token(raw,label,dataset,permissions,workspace_id): when workspace_id given the token is BOUND to it
    #   AND a Membership row is minted, role "admin" perm → "admin". A workspace-bound admin token satisfies require_admin.
    # CONCLUSION: reachable by a real non-super, workspace-bound admin token → its synonym writes/insights collapse to Default.

## Claim 3 — green tests pin NO per-workspace behavior on the FLAT path (finding genuinely open)

    CC=clang mix test test/barkpark/search/synonyms_cross_tenant_test.exs \
      test/barkpark/search/surface_config_cross_tenant_test.exs \
      test/barkpark/search/intel_cross_tenant_test.exs
    # → 14 tests, 0 failures
    # BUT: synonyms_cross_tenant + intel_cross_tenant call the MODULE layer (Synonyms.create/insights_hero with ws_id
    #      passed EXPLICITLY) — they bypass the controller collapse entirely.
    #      surface_config_cross_tenant hits HTTP but the FIXED settings route (search_settings_admin pipeline).
    #      test/barkpark_web/contract/search_synonyms_test.exs hits the flat HTTP route but with ONE Default-bound
    #      token and asserts only response SHAPE — one workspace in play, collapse unobservable.
    # No test drives the flat insights/synonym-write HTTP route with a workspace-bound token asserting isolation.

VERDICT: both search tenant findings are ABOVE-BAR and GENUINELY OPEN. Seal precondition FALSE. NOT-SEAL stands.
