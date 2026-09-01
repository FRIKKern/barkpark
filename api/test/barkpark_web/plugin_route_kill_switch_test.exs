defmodule BarkparkWeb.PluginRouteKillSwitchTest do
  @moduledoc """
  The `BARKPARK_PLUGINS` kill switch, asserted at the ROUTER, at REQUEST time.

  ## Why this file exists

  `test/barkpark_web/plugin_routes_test.exs` asserts that
  `Registry.collect_routes/1` returns `[]` under `put_env(:plugins, [])`, and
  says so honestly: "we cannot observe a runtime 404 without recompiling the
  router". That premise held while the switch was compile-time-only, and it is
  exactly why the defect survived — the collector was never the broken part.
  Under the kill switch the collector returned 0 routes in every bucket while
  the compiled router carried 41 `/v1/plugins/*` routes, and
  `POST /v1/plugins/pulse/:channel/events` took an unauthenticated, PERSISTED
  write on a surface the operator believed disabled.

  A collector-level assertion is structurally incapable of catching that
  class. Every assertion below therefore goes through the real endpoint, on a
  route that is STILL MOUNTED (asserted), with only `Application.put_env` — no
  recompile — between the two outcomes.

  ## The probe

  Pulse's `:public_api` bucket, the anonymous surface the incident ran through.
  Two traps this file is written around:

    * A status-only probe LIES here. An unconfigured pulse channel also 404s,
      from `pulse_controller.ex`'s own `channel_or_404/2` — i.e. the request
      cleared routing and ran plugin code. So every 404 assertion below also
      pins the BODY, and asserts it is NOT the controller's
      `"unknown pulse channel"` message. (The guard raises
      `Phoenix.Router.NoRouteError`; the endpoint's error layer renders it as
      an ordinary 404 rather than letting it escape, so these are plain
      `conn.status` assertions, not `assert_error_sent/2`.)
    * Pulse channels come from a SEPARATE switch (`:pulse_channels`), so the
      positive control matters: the same path, same channel, same request must
      return 200 with the plugin enabled. Without it, a 404 proves nothing.

  `async: false` + an `on_exit` restore: `:barkpark, :plugins` is node-global.
  Non-async modules are scheduled after every async module, so no concurrent
  test observes the swapped value.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.Plugins.Registry
  alias Barkpark.Pulse
  alias BarkparkWeb.Plugs.PluginRouteGuard

  setup :reset_rate_limiter!

  @channel "test-storm"
  @stats_path "/v1/plugins/pulse/#{@channel}/stats"
  @events_path "/v1/plugins/pulse/#{@channel}/events"

  # The compile-time spec of the route both probes hit, exactly as
  # `Barkpark.Plugins.Pulse.register_routes/1` declares it.
  @stats_spec {:get, "/pulse/:channel/stats", BarkparkWeb.PulseController, :stats,
               auth: :public_api}

  @valid_event %{"hue" => 200, "x" => 0.5, "y" => 0.25, "mega" => false}

  # Swap the installed-plugin whitelist for the duration of one test and put
  # the previous value back afterwards. `:error` is UNSET (discover-from-disk,
  # the production default) and is restored as unset — not as `[]`, which is a
  # different branch of `plugin_modules_sync/0` entirely.
  defp set_plugins!(value) do
    previous = Application.fetch_env(:barkpark, :plugins)

    on_exit(fn ->
      case previous do
        :error -> Application.delete_env(:barkpark, :plugins)
        {:ok, prev} -> Application.put_env(:barkpark, :plugins, prev)
      end
    end)

    Application.put_env(:barkpark, :plugins, value)
  end

  defp post_event(conn, body) do
    conn
    |> Map.put(:remote_ip, {203, 0, 113, 42})
    |> put_req_header("content-type", "application/json")
    |> post(@events_path, Jason.encode!(body))
  end

  describe "the route stays MOUNTED — this is a request-time guard, not a recompile" do
    test "the router table carries the pulse stats route" do
      route =
        Enum.find(
          BarkparkWeb.Router.__routes__(),
          &(&1.path == "/v1/plugins/pulse/:channel/stats" and &1.verb == :get)
        )

      refute is_nil(route),
             "expected /v1/plugins/pulse/:channel/stats to be compiled into the router"

      assert route.plug == BarkparkWeb.PulseController
    end
  end

  describe "plugin ENABLED — positive control" do
    setup do
      set_plugins!([Barkpark.Plugins.Pulse])
      :ok
    end

    test "the collector agrees the route is enabled" do
      specs = Registry.collect_routes(%{scope: :public_api, phase: :compile})
      keys = Enum.map(specs, &PluginRouteGuard.route_key/1)

      assert PluginRouteGuard.route_key(@stats_spec) in keys
    end

    test "GET stats answers normally, on a route carrying the guard stamp", %{conn: conn} do
      conn = get(conn, @stats_path)

      assert conn.status == 200

      body = json_response(conn, 200)
      assert is_map(body)
      assert Map.has_key?(body, "total")

      # The stamp the guard reads, observed on the conn the router built —
      # proof that the enabled 200 and the disabled 404 below are the SAME
      # compiled route, decided at request time.
      assert conn.private[PluginRouteGuard.private_key()] ==
               PluginRouteGuard.route_key(@stats_spec)
    end

    test "POST events records an anonymous strike", %{conn: conn} do
      before = Pulse.stats(@channel).total
      conn = post_event(conn, @valid_event)

      assert conn.status == 200
      assert json_response(conn, 200)["ok"] == true
      assert Pulse.stats(@channel).total == before + 1
    end
  end

  describe "kill switch engaged — plugins = []" do
    setup do
      set_plugins!([])
      :ok
    end

    test "GET stats 404s at request time, and NOT from the plugin controller", %{conn: conn} do
      conn = get(conn, @stats_path)

      assert conn.status == 404

      refute conn.resp_body =~ "unknown pulse channel",
             "a 404 from pulse_controller.ex means the request reached plugin code; " <>
               "the guard must stop it before dispatch. Body: " <> conn.resp_body
    end

    test "POST events 404s and persists NOTHING — the incident, closed", %{conn: conn} do
      before = Pulse.stats(@channel).total

      conn = post_event(conn, @valid_event)

      assert conn.status == 404
      refute conn.resp_body =~ "unknown pulse channel"

      assert Pulse.stats(@channel).total == before,
             "an unauthenticated write landed through a route the operator disabled"
    end

    test "the route is STILL in the router table — nothing was unmounted" do
      paths = Enum.map(BarkparkWeb.Router.__routes__(), & &1.path)
      assert "/v1/plugins/pulse/:channel/stats" in paths
    end
  end

  describe "kill switch engaged — a whitelist that excludes pulse" do
    setup do
      set_plugins!([Barkpark.Plugins.Bulldocs])
      :ok
    end

    test "an excluded plugin's route 404s even though other plugins are installed", %{conn: conn} do
      conn = get(conn, @stats_path)

      assert conn.status == 404
      refute conn.resp_body =~ "unknown pulse channel"
    end
  end
end
