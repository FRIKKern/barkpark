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

  Tagged `@moduletag :plugin_routes` so the default `mix test` run does
  not have to absorb the cost. Run explicitly:

      mix test --only plugin_routes test/barkpark_web/plugin_routes_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :plugin_routes

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
        build_conn()
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
        build_conn()
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
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/scoped-plugin-other-ws/p/other-proj/studio/onixedit/ping")

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "forbidden"
    end

    test "scoped admin LV → 404 for an unknown workspace slug", %{raw_token: raw} do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/no-such-ws/p/default/studio/onixedit/ping")

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "flat /studio/onixedit/ping still works (Default-scoped back-compat)", %{raw_token: raw} do
      conn =
        build_conn()
        |> init_test_session(%{"api_token" => raw})
        |> get(@pilot_path)

      assert html_response(conn, 200) =~ @body_marker
    end
  end
end
