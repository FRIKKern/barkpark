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
end
