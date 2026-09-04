defmodule BarkparkWeb.PluginRoutesTest do
  @moduledoc """
  Goal `barkpark-G2` task s5 — locks the plugin route highway end-to-end.

  Three assertions:

    1. With plugins loaded (default test env), the OnixEdit pilot
       `GET /studio/onixedit/ping` returns 200 + the body marker
       `"OnixEdit plugin route alive."`. Confirms OnixEdit's
       `register_routes/1` callback (s1), `Plugins.Registry.collect_routes/1`
       (s2), the `plugin_routes/1` macro inside `BarkparkWeb.Router` (s3),
       and the `PingLive` mount (s4) all wire together correctly.

    2. With `Application.put_env(:barkpark, :plugins, [])`,
       `Plugins.Registry.collect_routes/1` returns `[]` — proving the
       macro INPUT collapses to an empty list under the fresh-install
       invariant. The macro emits routes at compile time, so we cannot
       observe a runtime 404 without recompiling the router; asserting
       the registry's runtime output is the documented fallback
       (see `/lib/barkpark_web/router/plugins.ex` moduledoc: "With
       `:barkpark, :plugins` configured to `[]` … `collect_routes/1`
       returns `[]` and the macro emits no routes — preserving the
       fresh-install invariant.").

    3. `BarkparkWeb.Router.__routes__/0` introspection contains the
       pilot path. Compile-time registration succeeded, independent
       of any runtime request.

  RUNS IN THE DEFAULT LANE. This module used to carry
  `@moduletag :plugin_routes`, which `test/test_helper.exs` excludes and which no
  CI step ever re-includes (`.github/workflows/elixir.yml` runs a bare `mix test`
  plus one dedicated `--only boot_test` step; there is no `--only plugin_routes`
  step) — so the whole plugin-route highway lock, auth-bucket assertions
  included, had not run in CI at all. A test that cannot run cannot fail, so the
  tag is gone. The stated reason for it was the env mutation in describe 2 (and
  now describe 5), both of which are safe here: `async: false` modules are
  scheduled after every async module, so no concurrent test can observe
  `:barkpark, :plugins` while it is swapped, and both setups restore the previous
  value in `on_exit`. The whole file costs ~3.3s.

  The `:plugin_routes` tag itself stays registered in `test_helper.exs` — the
  plugin-route describe of `test/barkpark_web/studio/nav_parity_sweep_test.exs`
  still uses it, and that one mutates per-workspace plugin SETTINGS.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Registry

  @endpoint BarkparkWeb.Endpoint

  @pilot_path "/studio/onixedit/ping"
  @body_marker "OnixEdit plugin route alive."
  @admin_token "plugin-routes-admin-test-token"

  # ── Describe 1 — plugins loaded (default test env) ────────────────────

  describe "plugin route highway (plugins loaded — default)" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

      {:ok, _api_token} =
        Auth.create_token(
          @admin_token,
          "plugin routes test admin",
          "production",
          ["read", "write", "admin"]
        )

      :ok
    end

    test "GET /studio/onixedit/ping returns 200 with the pilot body marker" do
      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> init_test_session(%{"api_token" => @admin_token})
        |> get(@pilot_path)

      body = html_response(conn, 200)

      assert body =~ @body_marker,
             "expected body marker #{inspect(@body_marker)} in PingLive HTML, got #{byte_size(body)} bytes"
    end

    test "the pilot route appears in Phoenix.Router introspection" do
      paths =
        BarkparkWeb.Router.__routes__()
        |> Enum.map(& &1.path)

      assert @pilot_path in paths,
             "expected #{@pilot_path} in BarkparkWeb.Router.__routes__/0; got #{length(paths)} routes (none matched)"
    end
  end

  # ── Describe 2 — fresh-install invariant (plugins=[]) ─────────────────
  #
  # The `plugin_routes/1` macro consumes `Plugins.Registry.collect_routes/1`
  # at the host router's COMPILE time. We cannot recompile the router from
  # a test, so we lock the contract one layer below: with `:plugins` set
  # to `[]`, the registry's `collect_routes/1` returns `[]` — which is
  # the only input the macro reads. Empty input ⇒ empty AST ⇒ zero
  # plugin routes emitted at compile time. The macro's moduledoc
  # documents this as the fresh-install invariant.
  #
  # No app restart needed — `collect_routes/1` reads `Application.get_env`
  # synchronously inside `plugin_modules_sync/0` on every call, so a
  # `put_env` + immediate call is sufficient. Restore the previous value
  # in `on_exit` so describe 1 is unaffected by run order.

  describe "fresh-install invariant — plugins=[] (G1's contract)" do
    setup do
      prev_plugins = Application.get_env(:barkpark, :plugins, :unset)
      Application.put_env(:barkpark, :plugins, [])

      on_exit(fn ->
        case prev_plugins do
          :unset -> Application.delete_env(:barkpark, :plugins)
          v -> Application.put_env(:barkpark, :plugins, v)
        end
      end)

      :ok
    end

    test "Plugins.Registry.collect_routes/1 returns [] under plugins=[]" do
      routes = Registry.collect_routes(%{phase: :compile, scope: :admin})

      assert routes == [],
             "expected zero plugin routes under plugins=[]; got #{inspect(routes)}"
    end
  end

  # ── Describe 3 — workspace/project-scoped plugin mirrors (barkpark-4tuu) ─
  #
  # The flat plugin mounts stay as the Default-scoped back-compat alias;
  # these prove the new `/w/:ws/p/:project/{studio,admin,v1/plugins}`
  # mirrors mount the SAME plugin routes AND run ResolveWorkspace/
  # ResolveProject (the hard tenant boundary) ahead of them.

  describe "workspace/project-scoped plugin mirrors (barkpark-4tuu)" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

      # create_token/4 (no explicit workspace_id) binds to the seeded Default
      # workspace AND creates a membership — so this token is a Default member
      # with admin perms (the LV admin on_mount gate), but NOT a member of
      # "scoped-plugin-other-ws".
      raw = "scoped-plugin-admin-token-#{System.unique_integer([:positive])}"

      {:ok, _api_token} =
        Auth.create_token(raw, "scoped plugin admin", "production", ["read", "write", "admin"])

      {:ok, other_ws} =
        Barkpark.Tenancy.create_workspace(%{slug: "scoped-plugin-other-ws", name: "Other"})

      {:ok, _other_proj} =
        Barkpark.Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other"})

      {:ok, raw_token: raw}
    end

    test "scoped + flat plugin routes both appear in Router introspection" do
      paths = BarkparkWeb.Router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()

      # Flat back-compat alias still present.
      assert @pilot_path in paths
      assert "/v1/plugins/onixedit/export/:dataset/:id" in paths

      # New workspace/project-scoped mirrors present.
      assert "/w/:workspace_slug/p/:project_slug/studio/onixedit/ping" in paths
      assert "/w/:workspace_slug/p/:project_slug/admin/onixedit/bokbasen" in paths
      assert "/w/:workspace_slug/p/:project_slug/admin/onixedit/staleness" in paths

      assert "/w/:workspace_slug/p/:project_slug/v1/plugins/onixedit/export/:dataset/:id" in paths
    end

    test "scoped admin LV resolves workspace+project (member Bearer) and reaches the mount", %{
      raw_token: raw
    } do
      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/default/p/default/studio/onixedit/ping")

      body = html_response(conn, 200)

      assert body =~ @body_marker
      # The resolver plugs ran and set the hard-tenant-boundary assigns.
      assert conn.assigns.current_workspace.slug == "default"
      assert conn.assigns.current_project.slug == "default"
    end

    test "scoped admin LV → 403 for a token that is not a member of the target workspace", %{
      raw_token: raw
    } do
      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/scoped-plugin-other-ws/p/other-proj/studio/onixedit/ping")

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "forbidden"
    end

    test "scoped admin LV → 404 for an unknown workspace slug", %{raw_token: raw} do
      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/no-such-ws/p/default/studio/onixedit/ping")

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "flat /studio/onixedit/ping still works (Default-scoped back-compat)", %{raw_token: raw} do
      conn =
        BarkparkWeb.ConnCase.scoped_conn()
        |> init_test_session(%{"api_token" => raw})
        |> get(@pilot_path)

      assert html_response(conn, 200) =~ @body_marker
    end
  end

  # ── Describe 4 — plugin-route bucket selection, against the REAL macro ────
  #
  # WHY THIS REPLACED THE PREVIOUS DESCRIBES 4 AND 5 (vacuous-hunt-2).
  #
  # The two describes here used to assert against a hand-written COPY of the
  # macro's private `route_in_scope?/2` — a `select_for_scope/2` defined in
  # THIS file — plus, for the accepted-bucket claim, a literal atom's
  # membership in a literal list written on the same line:
  #
  #     assert :token in [:admin, :ops, :public, :api, :token, :ingest, :public_root]
  #
  # Neither expression referenced any module under `lib/`. Two proofs:
  #
  #   1. Extracted verbatim into a standalone script and run under plain
  #      `elixir` with the entire application ABSENT (no Mix, no deps, no
  #      compiled Barkpark): `4 tests, 0 failures`.
  #   2. In situ, mutating the real `auth_matches_scope?/2` in
  #      `lib/barkpark_web/router/plugins.ex` to `defp auth_matches_scope?(_, _),
  #      do: false` — so NO 5-tuple plugin route is emitted into ANY bucket,
  #      making "an `auth: :token` route is selected by scope :token" FALSE in
  #      production — left all four green. The mutation is proven to have landed
  #      because describe 3's router-introspection test reddened on the same run
  #      (`12 tests, 1 failure`, at :163).
  #
  # The copy had also DRIFTED: it listed 7 and 8 accepted scopes against the
  # macro's real 12 (`:session_token_root`, `:ticket_key`, `:public_api` and
  # `:github_webhook` were never in it) — so even read as documentation it
  # under-reported the surface.
  #
  # These tests expand the REAL macro. `plugin_routes/1` validates its `scope:`
  # and filters `Registry.collect_routes/1` through `route_in_scope?/2` during
  # MACRO EXPANSION, so `Macro.expand/2` is the honest seam onto both private
  # functions — the same code path the host router takes at compile time.

  require BarkparkWeb.Router.Plugins

  describe "plugin_routes/1 scope validation (the real guard list)" do
    test "an unknown scope raises ArgumentError naming the accepted buckets" do
      assert_raise ArgumentError, ~r/plugin_routes\(scope: \.\.\.\) requires/, fn ->
        expand_bucket(:not_a_real_bucket)
      end
    end

    # COMPLETENESS, PROVEN — not enumerated. The failure mode this closes: a
    # plugin declares `auth: :whatever` for which the host router has no
    # `plugin_routes(scope: :whatever)` callsite/bucket, so `route_in_scope?/2`
    # never matches it and the route is SILENTLY never emitted — no compile
    # error, no 404 anyone attributes to the plugin, the endpoint simply does
    # not exist. Deriving the left side from the registry (rather than listing
    # it) means a new plugin bucket cannot drift past this test.
    test "every auth: bucket declared by a registered plugin route is an accepted scope" do
      declared =
        %{phase: :compile}
        |> Registry.collect_routes()
        |> Enum.map(&declared_auth/1)
        |> Enum.uniq()
        |> Enum.sort()

      # Guard against the emptiness that would make the assertion below
      # vacuous: the default test env DOES load plugins that contribute routes.
      assert declared != [],
             "no plugin contributed any route — this completeness check would " <>
               "pass on an empty set, proving nothing"

      unaccepted = Enum.reject(declared, &accepted_bucket?/1)

      assert unaccepted == [],
             """
             These `auth:` values are declared by a registered plugin route but are
             NOT accepted by `plugin_routes(scope: ...)`, so `route_in_scope?/2`
             never selects them and every route carrying them is SILENTLY dropped
             at router compile time:

                 #{inspect(unaccepted)}

             Fix: add the bucket to the guard list in
             `lib/barkpark_web/router/plugins.ex` AND wrap a `plugin_routes(scope: ...)`
             callsite in `BarkparkWeb.Router` with the right pipeline — never just
             one of the two.
             """
    end
  end

  describe "plugin_routes/1 bucket FILTERING (real route_in_scope?/2)" do
    # A probe plugin whose four specs cover every branch of the real
    # `route_in_scope?/2`: a bare 4-tuple (defaults to :admin), an explicit
    # `auth: :token`, an explicit `auth: :token_root`, and `auth: :none` (the
    # spec-side name the `:public` bucket aliases).
    defmodule BucketProbePlugin do
      def register_routes(_ctx) do
        [
          {:get, "/probe/default-admin", BarkparkWeb.PageController, :index},
          {:post, "/probe/token", BarkparkWeb.PageController, :index, auth: :token},
          {:get, "/probe/token-root", BarkparkWeb.PageController, :index, auth: :token_root},
          {:get, "/probe/public", BarkparkWeb.PageController, :index, auth: :none}
        ]
      end
    end

    setup do
      prev = Application.get_env(:barkpark, :plugins, :unset)
      Application.put_env(:barkpark, :plugins, [BucketProbePlugin])

      on_exit(fn ->
        case prev do
          :unset -> Application.delete_env(:barkpark, :plugins)
          v -> Application.put_env(:barkpark, :plugins, v)
        end
      end)

      :ok
    end

    test "each probe route is emitted by its OWN bucket and by no other" do
      # {path, the one bucket that must emit it}
      expected = [
        {"/probe/default-admin", :admin},
        {"/probe/token", :token},
        {"/probe/token-root", :token_root},
        {"/probe/public", :public}
      ]

      all_buckets = Enum.map(expected, &elem(&1, 1)) ++ [:ops, :api, :ingest]

      for {path, owning_bucket} <- expected, bucket <- Enum.uniq(all_buckets) do
        # Match the QUOTED path in the emitted AST text, never a bare substring:
        # `/probe/token` is a prefix of `/probe/token-root`, and a substring test
        # reported a leak that was not there. The emitted form is always
        # `get("/probe/token", …)`, so the quotes make the match exact.
        emitted = expand_bucket(bucket) =~ ~s("#{path}")

        if bucket == owning_bucket do
          assert emitted,
                 "expected #{path} to be emitted by plugin_routes(scope: #{inspect(bucket)})"
        else
          refute emitted,
                 "#{path} LEAKED into plugin_routes(scope: #{inspect(bucket)}) — a route " <>
                   "emitted into a foreign bucket rides that bucket's pipeline, which is " <>
                   "how an admin-gated route ends up behind no on_mount at all"
        end
      end
    end

    test "the probe plugin is actually reaching the registry (guard against a silent empty scan)" do
      paths =
        %{phase: :compile}
        |> Registry.collect_routes()
        |> Enum.map(&elem(&1, 1))

      assert "/probe/token" in paths,
             "the probe plugin contributed nothing — every filtering assertion above " <>
               "would then be satisfied by emptiness. Got: #{inspect(paths)}"
    end
  end

  # ── helpers on the real macro ─────────────────────────────────────────────

  # Expand `plugin_routes(scope: scope)` exactly as `BarkparkWeb.Router` does at
  # compile time, and render the emitted router AST as text. Expansion is where
  # the scope guard raises and where `route_in_scope?/2` filters, so this reaches
  # both private functions without copying either.
  defp expand_bucket(scope) do
    quote(do: BarkparkWeb.Router.Plugins.plugin_routes(scope: unquote(scope)))
    |> Macro.expand(__ENV__)
    |> Macro.to_string()
  end

  defp accepted_bucket?(auth) do
    # `:none` is the spec-side opt value; `:public` is the callsite bucket name.
    scope = if auth == :none, do: :public, else: auth
    expand_bucket(scope)
    true
  rescue
    ArgumentError -> false
  end

  defp declared_auth({_kind, _path, _mod, _action}), do: :admin

  defp declared_auth({_kind, _path, _mod, _action, opts}) when is_list(opts),
    do: Keyword.get(opts, :auth, :admin)
end
