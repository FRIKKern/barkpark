defmodule BarkparkWeb.RevisionsReachabilityInvariantsTest do
  @moduledoc """
  THE TWO FACTS `task-5e29be5b8a90fbc4` CLOSED ON, PINNED.

  That row asked whether a nil `workspace_id` can reach the three fail-open
  `scope_to_workspace_or_global/3` arms in `Barkpark.Content.Revisions`
  (`list_revisions/4`, `get_revision/3`, `get_revision_by_rev/3`). The answer
  was NOT REACHABLE, and the three `# global-read:` markers on those arms rest
  on it.

  The verdict is true today and NOTHING ASSERTED IT. It rests on two facts that
  live in other modules entirely, so a refactor of either makes a closed
  security row silently false: the row stays closed, the markers keep reading
  "reviewed", and no test reds.

    1. HTTP: `ScopeHelpers.scope_opts/1` on a conn runs `:sentinel` mode, whose
       unresolved arm PUTS `workspace_id: :shared_only`. That value misses
       `scope_to_workspace_or_global(query, nil, _)` entirely and falls to the
       catch-all, which narrows to `is_nil(workspace_id)` — the shared layer,
       strictly NARROWER than global. Its `:legacy` sibling OMITS the key, which
       would yield `nil` and take the global arm. The two are one argument apart
       in the same function.

    2. SOCKET: `scope_opts/1` on a Socket uses `:legacy` and DOES omit the key,
       so a socket door WOULD deliver nil. It is safe only because
       `BarkparkWeb.Studio.StudioLive` is registered in exactly one `live_session`,
       `:scoped_studio`, whose `on_mount` carries `LiveScope`. A second
       registration without that hook reopens the door.

  This file does not narrow anything and does not touch the chokepoint. It
  fails when either fact stops being true.
  """
  use BarkparkWeb.ConnCase, async: true

  alias BarkparkWeb.ScopeHelpers

  # ── 1. THE HTTP SENTINEL ───────────────────────────────────────────────────

  describe "an unresolved conn yields the sentinel, never a missing key" do
    test "scope_opts/1 puts workspace_id: :shared_only when no workspace is assigned" do
      opts = ScopeHelpers.scope_opts(build_conn())

      # The distinction this guard exists for. `Keyword.fetch/2`, not
      # `Keyword.get/2`: the failure mode being caught is the key being ABSENT
      # (the `:legacy` shape), and `get` would report the same `nil` for an
      # absent key as for a key explicitly set to nil, so it cannot tell the
      # safe shape from the dangerous one.
      assert Keyword.fetch(opts, :workspace_id) == {:ok, :shared_only},
             """
             ScopeHelpers.scope_opts/1 on an UNRESOLVED conn no longer yields
             :shared_only. Got: #{inspect(Keyword.fetch(opts, :workspace_id))}

             If the key is now ABSENT (:error), the sentinel arm has been
             changed to the `:legacy` shape and every HTTP caller of
             Content.Revisions' three scope arms now takes the ALL-TENANTS
             global read on any request the routing layer failed to resolve.
             task-5e29be5b8a90fbc4 closed NOT REACHABLE on this line; that
             verdict is now false and the `# global-read:` markers in
             content/revisions.ex are no longer justified.

             MUTATION NOTE (how this test is known to discriminate): change
             `put_workspace_scope(opts, _unresolved, :sentinel)` in
             plugs/scope_helpers.ex to the `:legacy` body `do: opts` and this
             assertion reds with :error — the exact shape it guards against.
             """
    end

    test "the sentinel is NOT nil — the two failure shapes are told apart" do
      opts = ScopeHelpers.scope_opts(build_conn())

      refute Keyword.get(opts, :workspace_id) == nil,
             "workspace_id is nil, which takes scope_to_workspace_or_global/3's GLOBAL arm"
    end
  end

  # ── 2. THE SOCKET DOOR ─────────────────────────────────────────────────────

  describe "StudioLive is mounted only where a tenant resolver runs" do
    test "every live_session registering StudioLive carries the LiveScope on_mount" do
      registrations =
        for route <- BarkparkWeb.Router.__routes__(),
            {mod, _action, _opts, %{name: name, extra: %{on_mount: on_mount}}} <-
              [route.metadata[:phoenix_live_view]],
            mod == BarkparkWeb.Studio.StudioLive,
            uniq: true do
          {name, on_mount}
        end

      # POSITIVE CONTROL. Derived from the router, so if StudioLive is renamed,
      # moved, or the metadata shape changes, this guard would otherwise pass by
      # finding NOTHING and certify an invariant it never checked.
      refute registrations == [],
             """
             This guard found NO router registration of BarkparkWeb.Studio.StudioLive,
             so it is vacuous. StudioLive was renamed/moved, or the
             route.metadata[:phoenix_live_view] shape changed. Fix the scan —
             do not delete this test, because the socket door it guards is the
             one that omits the workspace key rather than sentinelling it.
             """

      for {session, on_mount} <- registrations do
        assert inspect(on_mount) =~ "LiveScope",
               """
               live_session #{inspect(session)} registers BarkparkWeb.Studio.StudioLive
               WITHOUT a LiveScope on_mount. on_mount: #{inspect(on_mount)}

               scope_opts/1 on a Socket uses :legacy mode and OMITS the
               workspace key when unresolved, so this session can now deliver a
               nil workspace_id into Content.Revisions' three fail-open scope
               arms — an all-tenants read of revision content.
               task-5e29be5b8a90fbc4 closed NOT REACHABLE precisely because
               :scoped_studio was the only registration and it carries LiveScope.
               """
      end
    end
  end
end
