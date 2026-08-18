<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# W2b V3 — DB-untouched + doors-disjoint + subsumption re-derivation

Verifier V3, Cloud-Build search-tenancy wave 2b. All facts from origin/main 3ddc00a0.

## Module + migration UNTOUCHED by both doors

Door 1 edits `search_controller.ex` handler bodies only; Door 2 edits `router.ex`
pipe_through only. Neither touches `search/synonyms.ex` nor the unique-index
migration. Byte-identity vs origin/main (worktree at a6535504):

    cd api && git diff --quiet origin/main HEAD -- lib/barkpark/search/synonyms.ex && echo SAME
    cd api && git diff --quiet origin/main HEAD -- priv/repo/migrations/20260715120000_search_synonyms_workspace_unique_index.exs && echo SAME

## DB per-tenant unique key still enforces (RAN)

    cd api && MIX_ENV=test MIX_TEST_PARTITION=v3db mix ecto.create --quiet
    cd api && MIX_ENV=test MIX_TEST_PARTITION=v3db mix ecto.migrate --quiet
    cd api && MIX_ENV=test MIX_TEST_PARTITION=v3db mix test test/barkpark/search/synonyms_cross_tenant_test.exs test/barkpark/search/intel_cross_tenant_test.exs
    # => 11 tests, 0 failures

Migration = two partial arms: `search_synonyms_null_ws_unique_idx`
(WHERE workspace_id IS NULL) + `search_synonyms_workspace_unique_idx`
(WHERE workspace_id IS NOT NULL). Two workspaces sharing scope 'production'
each own their row; same-tenant dup → 422 changeset, never raw 500.

## Doors file-disjoint

    git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | sed -n '252,313p'
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1966,1982p'

Door 1: create@252 / promote@262 / delete@313, none overlapping
update_search_settings@289-311 or helpers. Door 2: flat block pipe_through
`[:api,:require_admin]`@~1974 → flip to `:search_settings_admin`. Different files.

## Subsumption holds (Door 1 independently needed)

    git show origin/main:api/lib/barkpark/search/synonyms.ex | sed -n '426,440p'

`put_workspace_id(attrs, _) -> attrs` (nil no-op, line 429);
`scope_to_workspace(query, _) -> query` (workspace-blind, 440);
is_nil arm (437) makes a NULL-workspace row visible to all. So a genuinely
nil-workspace admin token under Door 2's fail-soft derive still writes a global
NULL row → Door 1's raw-token nil guard is not subsumed by Door 2.
