# V4 — scope_opts(conn) never yields workspace_id=nil on a route path (Felix w30)

VERDICT: ALREADY-GOOD. The premise ("can scope_opts yield workspace_id=nil") is
structurally impossible; the weaker leak question (workspace_id ABSENT →
related.ex:172 global-read) resolves NO on every request-reachable route.

## Re-derivation

    cd api

    # 1. scope_opts is imported from ScopeHelpers, not defined in the controller.
    grep -n 'scope_opts' lib/barkpark_web/controllers/query_controller.ex
    #   -> import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

    # 2. The chokepoint: put_scope/3 DROPS nil (and any non-%{id:}) — it can
    #    never emit the value `workspace_id: nil`. Key is present-with-real-id or absent.
    sed -n '62,88p' lib/barkpark_web/plugs/scope_helpers.ex
    #   def scope_opts(%Conn{assigns: a}), do: [memoize: true] ++ from_assigns(a)
    #   from_assigns -> put_scope(:workspace_id, Map.get(assigns, :current_workspace))
    #   defp put_scope(opts, _key, nil), do: opts               # nil -> DROP
    #   defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
    #   defp put_scope(opts, _key, _other), do: opts            # non-%{id:} -> DROP

    # 3. Absence (unscoped) requires current_workspace assign == nil. Every
    #    QueryController route sets it:
    grep -n 'QueryController' lib/barkpark_web/router.ex   # 4 mounts of related/2
    #   flat  /related          -> pipe_through([:api, :api_grant_read])   (router:1689)
    #   flat  preview /related  -> :api_preview                            (router:1731)
    #   /w.../v1/preview/...    -> :scoped_api                             (router:2223)
    #   /w.../v1/data/related   -> :shared_docs_api                        (router:2301)

    # 4. :api (router:43) and :api_preview (router:475) both run AssignDefaultScope
    #    -> stamps the seeded Default workspace (present on any backfilled/prod DB).
    # 5. :scoped_api / :shared_docs_api run ResolveWorkspace -> assign real ws
    #    (resolve_workspace.ex:103) OR halt 404/403 (:76,:131,:134); never continues nil.
    # 6. The anonymous share_public short-circuit (resolve_workspace.ex:66) is safe:
    #    RequireShareScope pre-assigns current_workspace+current_project FIRST.
    grep -n 'current_workspace\|share_public' lib/barkpark_web/plugs/require_share_scope.ex
    #   -> assign(:current_workspace, workspace) at :146 and :183, BEFORE the flag.

    # 7. related.ex:172 global-read bridge only fires on nil workspace_id — reached
    #    ONLY by a pre-backfill fresh DB (single-tenant world, nothing to leak).
    sed -n '152,173p' lib/barkpark/content/related.ex
    #   |> Scope.scope_to_workspace_or_global(workspace_id, project_id)
    #   scope.ex:155  scope_to_workspace_or_global(q, nil, _) -> global (untouched)

    # 8. Live proof — 8/8 green, incl. cross-tenant leak asserts:
    MIX_ENV=test mix test \
      test/barkpark_web/controllers/related_route_test.exs \
      test/barkpark_web/integration/preview_scope_leak_test.exs
    #   -> 8 tests, 0 failures

## So what

related.ex row closes ALREADY-GOOD. The Envelope-census scope-alignment
guarantee (every class-4 caller resolves schema under the same scope as the doc
read) holds: no non-admin authed/preview route can present workspace_id=nil to
the boundary. No buildable slice.
