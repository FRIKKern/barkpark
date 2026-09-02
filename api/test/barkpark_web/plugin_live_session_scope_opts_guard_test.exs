defmodule BarkparkWeb.PluginLiveSessionScopeOptsGuardTest do
  @moduledoc """
  THE GUARD FOR AN EMPTY SEAT (task-816bafcfbfc2f912).

  `live_session :plugin_public` and `live_session :plugin_ops` mount
  `{BarkparkWeb.StudioChrome, :default}` and NOTHING that resolves a tenant —
  no `{BarkparkWeb.LiveScope, :resolve}`, no `{BarkparkWeb.PluginScopeSession,
  :scope}` (their `:scoped_*` twins carry the latter; these two do not), and no
  `:workspace_slug` path segment to resolve from. The only thing that can assign
  `:current_workspace` on such a mount is `StudioChrome.default_scope_fallback/1`,
  which leaves the assign NIL when `Tenancy.get_default_workspace()` returns
  nothing — a durable, operator-reachable state.

  A LiveView mounted there that calls `BarkparkWeb.ScopeHelpers.scope_opts/1`
  gets NO `:workspace_id` key at all (the socket arm of `scope_opts/1` omits it;
  only the `%Plug.Conn{}` arm emits the `:shared_only` sentinel). That
  keyword list flows to `Content.Query.base_query/4` ->
  `Content.Scope.scope_to_workspace_or_global(q, nil, _)`, whose nil arm is
  `scope_to_workspace_global/1` — "returns the query untouched", i.e. EVERY
  tenant's rows. On `:plugin_public` the caller is anonymous
  (`LiveAuth.:fetch_api_token` does not halt); on `:plugin_ops` it is an ops seat.

  TODAY THAT SEAT IS EMPTY. Of the plugin `{:live, …}` routes, exactly one
  module imports `BarkparkWeb.ScopeHelpers` — `Barkpark.Plugins.Tickets.InboxLive`
  — and it is `auth: :admin`, so it mounts in `:plugin_admin`, not here. An empty
  seat is precisely what nothing can go red about, which is why this file exists:
  it is a GATE, not a comment. It fails the moment a plugin takes the seat.

  DETECTION MECHANISM. Structural, not textual: for a module, read the BEAM
  `ImpT` (imports) chunk via `:beam_lib.chunks(binary, [:imports])`. That table
  lists every remote `{M, F, A}` the compiled code calls, so it sees through
  `alias`, through `import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]`
  (Elixir resolves an import to a fully-qualified remote call at compile time),
  and through macro-generated call sites — a `grep` for the string sees none of
  those reliably. Two arms:

    * DIRECT — the LiveView's own ImpT contains `{BarkparkWeb.ScopeHelpers,
      :scope_opts, 1}` or its public twin `scope_opts_from_assigns/1`
      (`scope_opts/1` is a two-line transport unwrap in front of it, so the
      assigns door is the identical hazard under a different name).
    * ONE HOP — the LiveView calls into an application module that itself
      contains such an entry ("through a module that imports it").

  KNOWN BLIND SPOT, stated so it is not mistaken for coverage: a call made
  through `apply/3` or a captured function stored at runtime emits no ImpT
  entry. This guard catches written call sites, which is how the seat would
  actually be taken.

  RE-PROVING THIS GUARD (it is not enough to add a probe LiveView). The census
  arm reads the COMPILED router, and `plugin_routes/1` folds the plugin route
  table in at the router's COMPILE time via
  `Barkpark.Plugins.Registry.collect_routes/1`. Mix has no dependency edge from
  `router.ex` to a plugin's `register_routes/1` — the macro reads plugins off
  DISK — and Elixir 1.19 keys recompilation on content, not mtime, so `touch
  lib/barkpark_web/router.ex` does NOT rebuild it. A probe added to a plugin
  shows up in the `[negative arm]` inventory (that list comes from the registry
  at RUNTIME) while staying absent from the `[guard census]` (that list comes
  from the router). Edit `router.ex`'s CONTENT to force the rebuild, or the
  probe proves nothing. This is also why the guard is honest about production:
  the router it reads is the router that ships.
  """

  use ExUnit.Case, async: true

  # `scope_opts/1` is the function the row names. `scope_opts_from_assigns/1` is
  # its public twin — `scope_opts/1` is a two-line transport unwrap in front of
  # it — so a LiveView reaching the same unresolved read through the assigns door
  # is the identical hazard under a different name. Both are targets.
  @targets [
    {BarkparkWeb.ScopeHelpers, :scope_opts, 1},
    {BarkparkWeb.ScopeHelpers, :scope_opts_from_assigns, 1}
  ]

  # The two flat plugin live_sessions that mount StudioChrome with NO
  # tenant-resolving on_mount hook. Their `:scoped_*` twins are absent on
  # purpose: those carry `{BarkparkWeb.PluginScopeSession, :scope}`.
  @unscoped_plugin_sessions [:plugin_public, :plugin_ops]

  # Modules that must NOT be reported by the guard, and are asserted below to be
  # outside its census — the row's named negative controls.
  @out_of_census [
    Barkpark.Plugins.Tickets.InboxLive,
    BarkparkWeb.Studio.StudioLive,
    BarkparkWeb.SearchChannel
  ]

  # Modules the DETECTOR must find `scope_opts/1` in. Positive control: a
  # detector that reports "no offenders" is only informative if it can be shown
  # to find the offence where the offence exists. These three cover both call
  # shapes — `import … only: [scope_opts: 1]` (InboxLive, SearchChannel) and
  # `alias BarkparkWeb.ScopeHelpers` + `ScopeHelpers.scope_opts(socket)`
  # (StudioLive.Shared).
  @detector_positives [
    Barkpark.Plugins.Tickets.InboxLive,
    BarkparkWeb.SearchChannel,
    BarkparkWeb.Studio.StudioLive.Shared
  ]

  # ── Detection ──────────────────────────────────────────────────────────────

  # Remote calls compiled into `mod`, from the BEAM ImpT chunk. Raises rather
  # than returning "no calls" when the chunk cannot be read: a guard that cannot
  # see a module must go RED, never silently green.
  defp remote_calls!(mod) do
    case :code.get_object_code(mod) do
      {^mod, bin, _file} ->
        case :beam_lib.chunks(bin, [:imports]) do
          {:ok, {^mod, [imports: imports]}} ->
            imports

          other ->
            flunk("cannot read the imports chunk of #{inspect(mod)}: #{inspect(other)}")
        end

      :error ->
        flunk("cannot locate the .beam for #{inspect(mod)} — the guard cannot inspect it")
    end
  end

  defp direct_hit(mod), do: Enum.find(@targets, &(&1 in remote_calls!(mod)))

  defp calls_target?(mod), do: direct_hit(mod) != nil

  defp app_modules do
    {:ok, mods} = :application.get_key(:barkpark, :modules)
    mods
  end

  # Every application module whose own compiled code calls a target. A guarded
  # LiveView reaching any of these is the "through a module that imports it" arm.
  defp tainted_modules do
    for mod <- app_modules(),
        {^mod, bin, _file} <- [:code.get_object_code(mod)],
        {:ok, {^mod, [imports: imports]}} <- [:beam_lib.chunks(bin, [:imports])],
        Enum.any?(@targets, &(&1 in imports)),
        into: MapSet.new(),
        do: mod
  end

  # `:ok` or `{:fires, reason}` — the verdict the gate acts on.
  defp verdict(mod, tainted) do
    calls = remote_calls!(mod)

    case Enum.find(@targets, &(&1 in calls)) do
      {_m, f, a} ->
        {:fires, "calls BarkparkWeb.ScopeHelpers.#{f}/#{a} directly (or via `import`)"}

      nil ->
        case Enum.find(calls, fn {m, _f, _a} -> MapSet.member?(tainted, m) end) do
          nil ->
            :ok

          {m, f, a} ->
            {:fires, "calls #{inspect(m)}.#{f}/#{a}, and #{inspect(m)} itself calls scope_opts/1"}
        end
    end
  end

  # ── Router census ──────────────────────────────────────────────────────────

  defp guarded_routes do
    for route <- BarkparkWeb.Router.__routes__(),
        {mod, _action, _opts, %{name: name}} <-
          [route.metadata[:phoenix_live_view]],
        name in @unscoped_plugin_sessions do
      %{path: route.path, session: name, module: mod}
    end
  end

  defp plugin_live_specs do
    %{phase: :runtime}
    |> Barkpark.Plugins.Registry.collect_routes()
    |> Enum.filter(fn spec ->
      match?({:live, _p, _m, _a}, spec) or match?({:live, _p, _m, _a, _o}, spec)
    end)
    |> Enum.uniq()
  end

  defp auth_of({:live, _p, _m, _a}), do: :admin
  defp auth_of({:live, _p, _m, _a, opts}), do: Keyword.get(opts, :auth, :admin)

  defp spec_path({:live, p, _m, _a}), do: p
  defp spec_path({:live, p, _m, _a, _o}), do: p

  defp spec_mod({:live, _p, m, _a}), do: m
  defp spec_mod({:live, _p, m, _a, _o}), do: m

  # ── 1. THE PREMISE ─────────────────────────────────────────────────────────

  describe "premise — the two live_sessions really do mount without a scope resolver" do
    test "neither :plugin_public nor :plugin_ops carries a tenant-resolving on_mount hook" do
      sessions =
        BarkparkWeb.Router.__routes__()
        |> Enum.flat_map(fn route ->
          case route.metadata[:phoenix_live_view] do
            {_mod, _action, _opts, %{name: name, extra: %{on_mount: on_mount}}}
            when name in @unscoped_plugin_sessions ->
              [{name, on_mount}]

            _ ->
              []
          end
        end)
        |> Enum.uniq()

      # Non-vacuity: if the router stops emitting these sessions entirely this
      # file would pass by describing nothing.
      refute sessions == [],
             """
             No route in live_session :plugin_public or :plugin_ops exists in the router.
             This guard would then be vacuous. If the sessions were renamed, rename
             @unscoped_plugin_sessions with them; if they were deleted, delete this file.
             """

      for {name, on_mount} <- sessions do
        # The hooks ARE there (LiveAuth x2 + StudioChrome) — the premise is that
        # none of them resolves a tenant, not that the list is empty.
        assert is_list(on_mount) and on_mount != [],
               "live_session #{inspect(name)} has no on_mount list — read the router, not this file"

        rendered = inspect(on_mount)

        refute rendered =~ "LiveScope",
               "live_session #{inspect(name)} now carries LiveScope — this guard's premise changed"

        refute rendered =~ "PluginScopeSession",
               "live_session #{inspect(name)} now carries PluginScopeSession — premise changed"
      end
    end
  end

  # ── 2. THE GATE ────────────────────────────────────────────────────────────

  describe "gate — no LiveView in :plugin_public / :plugin_ops may call scope_opts/1" do
    test "every module mounted in either session is clean" do
      tainted = tainted_modules()
      routes = guarded_routes()

      IO.puts("""

      [guard census] LiveView routes under the unscoped plugin live_sessions:
      #{Enum.map_join(routes, "\n", fn r -> "  #{r.session}  #{r.path}  #{inspect(r.module)}" end)}
      [guard census] #{length(routes)} route(s); #{MapSet.size(tainted)} application module(s) call scope_opts/1.
      """)

      offenders =
        for r <- routes, {:fires, why} <- [verdict(r.module, tainted)] do
          "  #{inspect(r.module)} (live_session #{inspect(r.session)}, #{r.path}) — #{why}"
        end

      assert offenders == [],
             """
             A LiveView mounted in live_session :plugin_public / :plugin_ops calls
             BarkparkWeb.ScopeHelpers.scope_opts/1:

             #{Enum.join(offenders, "\n")}

             Neither session resolves a tenant. `scope_opts/1`'s SOCKET arm omits
             :workspace_id entirely (only the %Plug.Conn{} arm emits :shared_only), so
             the read reaches Content.Scope.scope_to_workspace_or_global(q, nil, _) —
             the arm that returns the query UNTOUCHED, i.e. every tenant's rows. On
             :plugin_public the caller is anonymous.

             Fixes, in order of preference:
               * mount the route in the `/w/:ws/p/:proj` scoped twin
                 (:scoped_plugin_public / :scoped_plugin_ops), which carry
                 {BarkparkWeb.PluginScopeSession, :scope}; or
               * add {BarkparkWeb.LiveScope, :resolve} to the flat session; or
               * have the LiveView state its own tenancy intent instead of
                 inheriting the transport's default (the
                 Barkpark.Plugins.Tickets.Thread.operator_scope/1 idiom: map an
                 absent OR nil :workspace_id to :shared_only before the read).

             Do NOT silence this by adding the module to an allowlist.
             """
    end
  end

  # ── 3. THE DETECTOR IS NOT BLIND ───────────────────────────────────────────

  describe "detector positive control — it finds scope_opts/1 where scope_opts/1 is" do
    test "both call shapes (import and alias) are detected" do
      for mod <- @detector_positives do
        assert calls_target?(mod),
               """
               The detector failed to find BarkparkWeb.ScopeHelpers.scope_opts/1 in
               #{inspect(mod)}, which calls it. The gate above is therefore not known
               to be able to see an offence, and its green means nothing.
               """
      end
    end

    test "and it does NOT report a module that has no such call" do
      refute calls_target?(Barkpark.Content.Scope),
             "Content.Scope does not call scope_opts/1; a detector reporting it is over-firing"
    end
  end

  # ── 4. NEGATIVE ARM — the current plugin LiveView inventory ────────────────

  describe "negative arm — the guard fires on none of today's plugin LiveView routes" do
    test "every plugin {:live, …} route, and the three named socket consumers, are clean" do
      tainted = tainted_modules()
      specs = plugin_live_specs()
      guarded_mods = guarded_routes() |> Enum.map(& &1.module) |> MapSet.new()

      rows =
        for spec <- specs do
          mod = spec_mod(spec)
          auth = auth_of(spec)
          in_census = MapSet.member?(guarded_mods, mod)
          v = verdict(mod, tainted)
          {spec_path(spec), mod, auth, in_census, v}
        end

      IO.puts("""

      [negative arm] plugin LiveView route inventory (#{length(rows)} routes):
      #{Enum.map_join(rows, "\n", fn {p, m, auth, in_census, v} -> "  #{String.pad_trailing(p, 26)} auth: #{String.pad_trailing(inspect(auth), 14)} guarded: #{in_census}  verdict: #{inspect(v)}  #{inspect(m)}" end)}
      """)

      refute rows == [], "the plugin route registry returned no LiveView routes — vacuous"

      # The guard FIRES on a route iff the route is inside the census AND the
      # module calls a target. Those are two different facts, and conflating them
      # is the mistake this arm exists to avoid: `Tickets.InboxLive` DOES call
      # scope_opts/1 and is still clean here, because `auth: :admin` puts it in
      # `live_session :plugin_admin`, outside the two unscoped sessions.
      for {path, mod, _auth, in_census, v} <- rows do
        refute in_census and v != :ok,
               "#{path} (#{inspect(mod)}) fires the guard: #{inspect(v)}"
      end

      # Not vacuous about InboxLive: assert the thing that actually saves it.
      # If it ever stops calling scope_opts/1 this line reds and the row's
      # "only one plugin LiveView uses it" premise needs re-reading.
      assert match?({:fires, _}, verdict(Barkpark.Plugins.Tickets.InboxLive, tainted)),
             """
             Barkpark.Plugins.Tickets.InboxLive no longer calls scope_opts/1. The row's
             enumeration ("of the 13 plugin LiveView routes, exactly one imports
             ScopeHelpers") is stale — re-read it before trusting this arm.
             """

      refute MapSet.member?(guarded_mods, Barkpark.Plugins.Tickets.InboxLive),
             "InboxLive calls scope_opts/1; only its live_session keeps it clean"

      # At least one route is genuinely INSIDE the census, so the pass above is
      # not "green because the census is empty".
      assert Enum.any?(rows, fn {_p, _m, _a, in_census, _v} -> in_census end),
             "no plugin LiveView route is inside the guarded census — the negative arm is vacuous"

      # The three named negative controls: none is in the guarded census, so the
      # guard cannot fire on them however they use scope_opts/1.
      for mod <- @out_of_census do
        refute MapSet.member?(guarded_mods, mod),
               "#{inspect(mod)} is now mounted in :plugin_public / :plugin_ops — re-verify the row"
      end
    end
  end
end
