defmodule BarkparkWeb.Studio.NavParitySweepTest do
  @moduledoc """
  The wave-1 spine for the Studio nav-shell epic (`bp-studio-nav-shell`):
  a route-sweep proof that the persistent navigation chrome is IDENTICAL
  on every studio-layout LiveView and that each page highlights exactly
  the one tab it belongs to — the concrete regression guard for
  "nav items vanish or reorder depending on the page".

  Two layers:

    1. **Completeness guard (`studio-layout route set == curated table`)**
       — reflection over `BarkparkWeb.Router.__routes__()` filtered to
       `Phoenix.LiveView.Plug` mounts whose live_session layout is
       `{BarkparkWeb.Layouts, :studio}`. Every such route MUST appear in
       the curated `@routes` table below, so a NEW studio-layout route
       cannot silently dodge the parity contract — adding one reds this
       test until its author classifies it here.

    2. **Parity sweep (mount every curated route, compare the nav DOM)**
       — each mountable row is mounted with REAL fixture-built URLs
       (`ConnCase.scoped_studio/1` seeds the Default workspace/project;
       scoped routes 404 on fabricated slugs) and an admin token session.
       The `[data-test-id="top-menu-tab"]` anchors are parsed with
       `LazyHTML` (the LiveViewTest DOM dep — Floki is NOT a dependency).
       We assert, for a given user + enablement context:

         * the ordered tab-LABEL set is identical across ALL mounted
           routes (hrefs are NOT compared — `scope_prefix` legally varies
           the path between flat `/studio/...` and scoped `/w/.../studio`);
         * at most one tab carries the `active` class, and the active tab
           (when a route has a corresponding tab) is the one the route
           belongs to.

  ## Dispositions (`:disposition` in `@routes`)

    * `:mount` — mounted in the default sweep (default plugin enablement,
      admin token). `:active` names the tab that must highlight, or
      `:none` for a secondary surface (settings / org-admin) that has no
      corresponding top-tab and therefore highlights nothing. See the
      RESIDUAL GAP note below.
    * `:plugin` — mounted behind the globally-excluded `:plugin_routes`
      tag (see `test/test_helper.exs`), which first enables the owning
      plugin for the Default workspace so its tab surfaces. Run with
      `mix test --include plugin_routes`.
    * `:skip_env_gated` — `/studio/tmux` + `/studio/chat[/:session_id]`
      hard-gate their MOUNT on `TmuxConsole.enabled?/0` /
      `ClaudeChat.enabled?/0` (both off in test env). Not mounted; their
      TABS are gated by the SAME predicates, so the env-gated-lockstep
      assertion below computes the expected presence from those exact
      predicates — oracle and component never drift.
    * `:reflect_only` — other installed-plugin routes (pulse,
      onixedit ping/staleness, github) and their scoped `/w/:ws/p/:proj`
      mirrors. Counted by the completeness guard so they can't dodge the
      contract; not mounted here (each needs its own plugin-enable +
      data fixtures — out of scope for the shell-parity spine, covered by
      the two representative `:plugin` rows).

  ## RESIDUAL GAP (settings / org-admin highlight nothing)

  The scoped `/w/:ws/p/:proj/studio/settings` (moved off the flat
  `/studio/settings` by sdl-w1-admin-canonical) and the flat
  `/studio/org-admin` are BOTH dataset-less: the nav's built-in tab paths
  carry a `/d/:dataset/studio` segment, so neither page path prefix-matches
  a Structure/Media/API tab. No wave-1 slice adds a Settings or Org-admin
  top-tab, so these surfaces still highlight NO primary tab. That is
  encoded here as `active: :none` (the shell is still identical — parity
  holds — it just doesn't falsely highlight). If a later slice promotes
  them to real tabs, flip `:active` and this test enforces it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias BarkparkWeb.Studio.{ClaudeChat, TmuxConsole}

  @studio_layout {BarkparkWeb.Layouts, :studio}

  @admin_token "nav-parity-sweep-admin-token"

  # ── The curated mount table — ONE row per studio-layout live route ──────
  #
  # `:route` is the Phoenix route PATTERN (matches `Route.path` from
  # reflection). `:url` is the concrete, mountable URL: a literal string,
  # or `{:scoped, tail}` resolved through `scoped_studio/1` at runtime with
  # real seeded slugs. `:active` is the tab label that must highlight
  # (`:none` = no corresponding tab). See the moduledoc for dispositions.
  @routes [
    # ── core scoped Studio (the canonical /w/:ws/p/:proj/d/:ds address) ──
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio",
      disposition: :mount,
      url: {:scoped, "/d/production/studio"},
      active: "Structure"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/media",
      disposition: :mount,
      url: {:scoped, "/d/production/studio/media"},
      active: "Media"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/api-tester",
      disposition: :mount,
      url: {:scoped, "/d/production/studio/api-tester"},
      active: "API"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/*path",
      disposition: :mount,
      # the StudioLive catch-all — any non-media/api-tester sub-path is
      # Structure's territory.
      url: {:scoped, "/d/production/studio/post"},
      active: "Structure"
    },
    # ── admin singletons ──
    # settings moved to the workspace-scoped canonical
    # /w/:ws/p/:proj/studio/settings (sdl-w1-admin-canonical): SettingsLive
    # edits ONE workspace's substance, so its home is scoped. The flat
    # /studio/settings is now a 302 (AdminStudioRedirectController), NOT a
    # studio-layout live route — it reflects out of this table. org-admin
    # stays genuinely flat/scope-free (still highlights no tab).
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/settings",
      disposition: :mount,
      url: {:scoped, "/studio/settings"},
      # ssp-w3: Settings now has its own admin top-menu tab, so its route
      # highlights itself (a page must tell you where you are).
      active: "Settings"
    },
    # Connectors (connectors D49) — the same shape as settings: scoped-in-substance
    # (an install belongs to ONE workspace), so the canonical route is scoped and
    # the flat `/studio/connectors` is a 302 that reflects out of this table. It
    # has its own top-menu tab, so it highlights itself.
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/connectors",
      disposition: :mount,
      url: {:scoped, "/studio/connectors"},
      active: "Connectors"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/chat-hosts",
      disposition: :mount,
      url: {:scoped, "/studio/chat-hosts"},
      active: :none
    },
    %{route: "/studio/org-admin", disposition: :mount, url: "/studio/org-admin", active: :none},
    %{
      route: "/studio/styleguide",
      disposition: :mount,
      url: "/studio/styleguide",
      active: "Style"
    },
    # ── dataset-scoped admin LVs — moved under the canonical
    #    /w/:ws/p/:proj/d/:ds/studio/_plugins[...] (sdl-w1-admin-canonical),
    #    declared before the :scoped_studio /*path catch-all. Still
    #    Structure's territory: the scoped _plugins path is a boundary prefix
    #    of the scoped Structure tab base (/w/.../d/:ds/studio), so it
    #    highlights Structure exactly as the flat form did (prefix match). ──
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins",
      disposition: :mount,
      url: {:scoped, "/d/production/studio/_plugins"},
      active: "Structure"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins/:plugin/settings",
      disposition: :mount,
      url: {:scoped, "/d/production/studio/_plugins/onixedit/settings"},
      active: "Structure"
    },

    # ── env-gated (mount hard-gates on the enabled? predicate; off in test) ──
    %{route: "/studio/tmux", disposition: :skip_env_gated, gated: :tmux},
    %{route: "/studio/chat", disposition: :skip_env_gated, gated: :chat},
    %{route: "/studio/chat/:session_id", disposition: :skip_env_gated, gated: :chat},
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/chat",
      disposition: :skip_env_gated,
      gated: :chat
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/chat/:session_id",
      disposition: :skip_env_gated,
      gated: :chat
    },

    # ── representative plugin routes (mounted behind :plugin_routes tag) ──
    %{
      route: "/admin/projects",
      disposition: :plugin,
      plugin: "tasks",
      url: "/admin/projects",
      active: "Projects"
    },
    %{
      route: "/admin/fleet",
      disposition: :plugin,
      plugin: "tasks",
      url: "/admin/fleet",
      active: "Fleet"
    },
    %{
      route: "/admin/onixedit/bokbasen",
      disposition: :plugin,
      plugin: "onixedit",
      url: "/admin/onixedit/bokbasen",
      active: "Bokbasen"
    },
    %{
      route: "/studio/tickets",
      disposition: :plugin,
      plugin: "tickets",
      url: "/studio/tickets",
      active: "Tickets"
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/tickets",
      disposition: :plugin,
      plugin: "tickets",
      url: {:scoped, "/studio/tickets"},
      active: "Tickets"
    },

    # ── other installed-plugin routes — counted, not mounted here ──
    %{route: "/studio/onixedit/ping", disposition: :reflect_only},
    %{route: "/admin/pulse", disposition: :reflect_only},
    %{route: "/admin/onixedit/staleness", disposition: :reflect_only},
    %{route: "/admin/github", disposition: :reflect_only},
    # scoped /w/:ws/p/:proj mirrors of the plugin routes
    %{
      route: "/w/:workspace_slug/p/:project_slug/studio/onixedit/ping",
      disposition: :reflect_only
    },
    %{route: "/w/:workspace_slug/p/:project_slug/admin/projects", disposition: :reflect_only},
    %{route: "/w/:workspace_slug/p/:project_slug/admin/fleet", disposition: :reflect_only},
    %{route: "/w/:workspace_slug/p/:project_slug/admin/pulse", disposition: :reflect_only},
    %{
      route: "/w/:workspace_slug/p/:project_slug/admin/onixedit/bokbasen",
      disposition: :reflect_only
    },
    %{
      route: "/w/:workspace_slug/p/:project_slug/admin/onixedit/staleness",
      disposition: :reflect_only
    },
    %{route: "/w/:workspace_slug/p/:project_slug/admin/github", disposition: :reflect_only}
  ]

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "nav parity sweep admin", "production", [
        "read",
        "write",
        "admin"
      ])

    :ok
  end

  # ── Layer 1: completeness guard ─────────────────────────────────────────

  describe "reflection completeness guard" do
    test "every studio-layout live route is curated in @routes (no route dodges the contract)" do
      reflected = reflected_studio_routes() |> MapSet.new()
      curated = @routes |> Enum.map(& &1.route) |> MapSet.new()

      missing = MapSet.difference(reflected, curated)
      extra = MapSet.difference(curated, reflected)

      assert MapSet.size(missing) == 0,
             "studio-layout route(s) NOT curated in @routes — add a row (pick a " <>
               ":disposition) so the nav-parity contract covers them:\n" <>
               format_routes(missing)

      assert MapSet.size(extra) == 0,
             "@routes lists route(s) that no longer resolve to a studio-layout " <>
               "live mount — remove the stale row(s):\n" <> format_routes(extra)
    end

    test "the curated table has no duplicate route rows" do
      routes = Enum.map(@routes, & &1.route)
      dupes = routes -- Enum.uniq(routes)
      assert dupes == [], "duplicate route rows in @routes: #{inspect(dupes)}"
    end
  end

  # ── Layer 2: parity sweep over the default-enablement studio-layout LVs ──

  describe "nav parity across the default studio-layout sweep" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      mounts = for row <- rows(:mount), do: {row, mount_nav(conn, row)}
      {:ok, mounts: mounts}
    end

    test "the ordered tab-label set is IDENTICAL on every mounted route", %{mounts: mounts} do
      [{ref_row, ref_nav} | rest] = mounts
      reference = labels(ref_nav)

      assert reference != [],
             "reference route #{ref_row.route} rendered NO nav tabs — the shell " <>
               "vanished entirely"

      for {row, nav} <- rest do
        assert labels(nav) == reference,
               "nav tabs DIFFER on #{row.route}\n  reference (#{ref_row.route}): " <>
                 "#{inspect(reference)}\n  this route:              #{inspect(labels(nav))}"
      end
    end

    test "env-gated tabs (tmux/chat) are present iff their predicate holds — oracle in lockstep",
         %{mounts: [{_row, nav} | _]} do
      present = labels(nav) |> Enum.filter(&(&1 in ["tmux", "chat"]))

      expected =
        [] ++
          if(TmuxConsole.enabled?(), do: ["tmux"], else: []) ++
          if(ClaudeChat.enabled?(), do: ["chat"], else: [])

      assert Enum.sort(present) == Enum.sort(expected),
             "env-gated tab presence #{inspect(present)} disagrees with the same " <>
               "predicates the component uses #{inspect(expected)}"
    end

    test "every mounted route highlights exactly its own tab (or none for a non-tab surface)",
         %{mounts: mounts} do
      # Accumulate ALL mismatches so a single run shows the full picture
      # (pre-fix: api-tester / styleguide / _plugins all highlight nothing).
      violations =
        for {row, nav} <- mounts,
            actives = nav |> Enum.filter(& &1.active) |> Enum.map(& &1.label),
            expected = expected_actives(row.active),
            actives != expected do
          "  #{row.route}\n    expected active: #{inspect(expected)}\n" <>
            "    actual active:   #{inspect(actives)}"
        end

      assert violations == [],
             "active-tab highlighting is wrong on #{length(violations)} route(s) " <>
               "(zero active = the page does not tell you where you are; two = it " <>
               "claims two locations):\n" <> Enum.join(violations, "\n")
    end
  end

  # ── Layer 2b: representative plugin routes (opt-in, plugin-enable fixtures) ──

  describe "nav parity on plugin routes (enabled per workspace)" do
    @describetag :plugin_routes

    setup %{conn: conn} do
      {ws, _proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

      # Surface every plugin that owns a mounted plugin route for the Default
      # workspace (the flat /admin/* routes resolve to the Default scope), so
      # its top-menu tab appears next to the built-ins.
      overrides =
        for %{plugin: name} <- rows(:plugin), into: %{} do
          {name, %{"enabled" => true, "placement" => "top_menu"}}
        end

      {:ok, _} = Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, overrides)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      mounts = for row <- rows(:plugin), do: {row, mount_nav(conn, row)}
      {:ok, mounts: mounts}
    end

    test "the plugin routes share one nav and each highlights its own tab", %{mounts: mounts} do
      [{_ref_row, ref_nav} | rest] = mounts
      reference = labels(ref_nav)

      # Both representative plugin tabs must be present in the shared nav.
      for label <- ["Projects", "Bokbasen", "Tickets"] do
        assert label in reference,
               "expected #{label} tab in the plugin-enabled nav: #{inspect(reference)}"
      end

      for {row, nav} <- rest do
        assert labels(nav) == reference,
               "plugin-route nav DIFFERS on #{row.route}: #{inspect(labels(nav))} vs " <>
                 "#{inspect(reference)}"
      end

      for {row, nav} <- mounts do
        actives = nav |> Enum.filter(& &1.active) |> Enum.map(& &1.label)

        assert actives == [row.active],
               "#{row.route} should highlight exactly #{inspect(row.active)}, got " <>
                 "#{inspect(actives)}"
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp rows(disposition), do: Enum.filter(@routes, &(&1.disposition == disposition))

  # The oracle's active-label list for a route: `[]` for a non-tab surface,
  # `[label]` otherwise. A route must highlight EXACTLY this set — never two
  # (claiming two locations), never zero on a tab-backed page.
  defp expected_actives(:none), do: []
  defp expected_actives(label) when is_binary(label), do: [label]

  # Mount `row.url` and return the ordered nav model: a list of
  # `%{label, active}` — one per `[data-test-id="top-menu-tab"]` anchor.
  defp mount_nav(conn, row) do
    url = concrete_url(row.url)

    case live(conn, url) do
      {:ok, _view, html} ->
        parse_nav(html)

      other ->
        flunk("could not mount #{row.route} at #{url}: #{inspect(other)}")
    end
  end

  defp concrete_url({:scoped, tail}), do: scoped_studio(tail)
  defp concrete_url(url) when is_binary(url), do: url

  defp parse_nav(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-test-id="top-menu-tab"]))
    |> Enum.map(fn el ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(el))
      # Icons-only tabs (sup-w1): the human label rides aria-label; visible
      # text is gone. Fall back to text so a future labelled tab still parses.
      aria = frag |> LazyHTML.attribute("aria-label") |> List.first()
      text = frag |> LazyHTML.text() |> String.trim()
      label = if aria && aria != "", do: aria, else: text
      class = frag |> LazyHTML.attribute("class") |> List.first() || ""
      %{label: label, active: css_has_class?(class, "active")}
    end)
  end

  defp css_has_class?(class, name), do: name in String.split(class, ~r/\s+/, trim: true)

  defp labels(nav), do: Enum.map(nav, & &1.label)

  # Reflection: studio-layout live routes as their path PATTERNS.
  defp reflected_studio_routes do
    BarkparkWeb.Router.__routes__()
    |> Enum.filter(&studio_layout_live?/1)
    |> Enum.map(& &1.path)
  end

  defp studio_layout_live?(%{plug: Phoenix.LiveView.Plug} = route) do
    case route.metadata do
      %{phoenix_live_view: {_view, _action, _opts, %{extra: %{layout: layout}}}} ->
        layout == @studio_layout

      _ ->
        false
    end
  end

  defp studio_layout_live?(_), do: false

  defp format_routes(set), do: set |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")
end
