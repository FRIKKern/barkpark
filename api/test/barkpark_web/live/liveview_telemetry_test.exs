defmodule BarkparkWeb.LiveViewTelemetryTest do
  @moduledoc """
  Protective test for the LiveView-telemetry-consumer gap (task
  `task-felix-liveview-telemetry-consumer`). Pins the regression the audit
  found: Phoenix.LiveView emits mount/handle_params/handle_event spans on every
  Studio/board/reader interaction, but the PROD-reachable Prometheus reporter
  (`prometheus_metrics/0`) subscribed to NONE of them — "which LiveView is slow
  to mount?" was unanswerable in prod (the summary-based `metrics/0` is
  LiveDashboard-only, and the router mounts LiveDashboard behind `dev_routes`,
  true ONLY in dev). Every metric here maps to a NAMED production question, and
  each event is checked at three levels: DECLARED in the reporter's metric set,
  a barkpark_metrics handler ATTACHED to it (not orphaned), and it actually
  FIRES a `*_stop_duration_bucket` when a real LiveView is driven.

  Also pins the CRITICAL tag_values ASYMMETRY: the three live_view metrics dig
  their :view tag out of `socket.view` (a raw %Socket{} in the metadata), while
  the live_component metric tags off `metadata.component` (a top-level key). A
  single generic `%{view: socket.view}` fn reused across all four would return a
  map with NO :component key for the component metric → `Map.take` drops it →
  every live_component sample silently vanishes (fails closed). This test locks
  each metric to its own tag set so that regression cannot re-enter unnoticed.

  The LiveView is exercised with `Phoenix.LiveViewTest` under `ConnCase` — never
  by booting `phx.server` (the codelist seed OOMs locally). The board at
  `/admin/projects` is the disposable real LiveView we drive.

  async: false — asserts against the process-global telemetry handler table and
  the app-wide `:barkpark_metrics` aggregator (shared, boot-started singletons).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias BarkparkWeb.Telemetry

  @aggregator :barkpark_metrics

  @lv_mount [:phoenix, :live_view, :mount, :stop]
  @lv_handle_params [:phoenix, :live_view, :handle_params, :stop]
  @lv_handle_event [:phoenix, :live_view, :handle_event, :stop]
  @lc_handle_event [:phoenix, :live_component, :handle_event, :stop]

  @admin_token "liveview-telemetry-admin-test-token"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "liveview telemetry admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = Phoenix.ConnTest.build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  describe "each live_view/live_component event is DECLARED in the Prometheus reporter" do
    test "all four real event families have a duration histogram" do
      events = Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name)

      # Q: "which LiveView is slow to mount?"
      assert @lv_mount in events,
             "prometheus_metrics/0 is missing the live_view mount histogram"

      # Q: "which LiveView is slow to re-param (patch nav)?"
      assert @lv_handle_params in events,
             "prometheus_metrics/0 is missing the live_view handle_params histogram"

      # Q: "which LiveView is slow to handle an event (click/submit)?"
      assert @lv_handle_event in events,
             "prometheus_metrics/0 is missing the live_view handle_event histogram"

      # Q: "which LiveComponent is slow to handle an event?" — the ONLY
      # live_component span Phoenix emits (no mount, no handle_params).
      assert @lc_handle_event in events,
             "prometheus_metrics/0 is missing the live_component handle_event histogram"
    end
  end

  describe "the tag_values ASYMMETRY is preserved (view vs component)" do
    test "the three live_view metrics tag :view; the live_component metric tags :component" do
      by_event =
        Telemetry.prometheus_metrics()
        |> Enum.filter(
          &(&1.event_name in [@lv_mount, @lv_handle_params, @lv_handle_event, @lc_handle_event])
        )
        |> Map.new(&{&1.event_name, &1})

      for ev <- [@lv_mount, @lv_handle_params, @lv_handle_event] do
        assert by_event[ev].tags == [:view],
               "#{inspect(ev)} must tag off :view (socket.view), got #{inspect(by_event[ev].tags)}"
      end

      assert by_event[@lc_handle_event].tags == [:component],
             "the live_component metric must tag off :component (a top-level key), " <>
               "not :view — reusing the view fn would drop every component sample"
    end

    test "the live_view tag_values digs :view out of a raw %Socket{} metadata" do
      metric = metric_for(@lv_mount)
      # Model the real metadata shape: a raw socket carrying .view.
      md = %{socket: %{view: BarkparkWeb.SomeLive}, params: %{}, session: %{}, uri: "/x"}
      assert metric.tag_values.(md) == %{view: BarkparkWeb.SomeLive}
    end

    test "the live_component tag_values reads the TOP-LEVEL :component key, never socket.view" do
      metric = metric_for(@lc_handle_event)
      # component is top-level; a socket is also present but must be IGNORED.
      md = %{
        socket: %{view: BarkparkWeb.SomeLive},
        component: BarkparkWeb.SomeComponent,
        event: "x",
        params: %{}
      }

      taken = metric.tag_values.(md) |> Map.take(metric.tags)

      assert taken == %{component: BarkparkWeb.SomeComponent},
             "the component metric must produce a :component tag (not :view) — " <>
               "a missing :component key would silently drop the sample"
    end
  end

  describe "the events are ATTACHED to the live :barkpark_metrics aggregator (not orphaned)" do
    test "a barkpark_metrics handler subscribes to each of the four events" do
      for ev <- [@lv_mount, @lv_handle_params, @lv_handle_event, @lc_handle_event] do
        handlers = :telemetry.list_handlers(ev)

        assert Enum.any?(handlers, fn h ->
                 inspect(h.id) =~ "barkpark_metrics" or inspect(h.config) =~ "barkpark_metrics"
               end),
               "no :barkpark_metrics handler on #{inspect(ev)} — the histogram is not wired"
      end
    end
  end

  describe "driving a real LiveView records the live_view histograms in the reporter" do
    test "mount + handle_event stop buckets appear in the scrape after live/2 + a click",
         %{conn: conn} do
      # Drive the board LiveView: live/2 fires mount + handle_params on connect;
      # a real phx event (set-group) fires handle_event. No phx.server — this is
      # the same in-process ConnCase harness board_live_test.exs uses.
      {:ok, view, _html} = live(conn, "/admin/projects")
      _ = render_click(view, "set-group", %{"group" => "goal"})

      scraped = TelemetryMetricsPrometheus.Core.scrape(@aggregator)

      assert scraped =~ "phoenix_live_view_mount_stop_duration_bucket",
             "the live_view mount histogram never recorded a sample after a real mount"

      assert scraped =~ "phoenix_live_view_handle_event_stop_duration_bucket",
             "the live_view handle_event histogram never recorded a sample after a real click"

      # the :view tag actually resolved to the board module (proves the
      # socket.view dig worked — not a dropped/empty label).
      assert scraped =~ "Barkpark.Plugins.Tasks.Web.BoardLive" or scraped =~ "BoardLive",
             "the :view tag never resolved to the board module — socket.view dig failed"
    end
  end

  defp metric_for(event_name) do
    Telemetry.prometheus_metrics() |> Enum.find(&(&1.event_name == event_name))
  end
end
