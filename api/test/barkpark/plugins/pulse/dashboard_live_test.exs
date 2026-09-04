defmodule Barkpark.Plugins.Pulse.DashboardLiveTest do
  @moduledoc """
  The read-only Studio dashboard for Pulse channels: it mounts under
  `/studio/pulse` (admin), shows each channel's durable total, ticks live on a
  strike broadcast, and is linked from the Structure desk via `desk_items/1`.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.QueryCounter

  import Phoenix.LiveViewTest

  alias Barkpark.Pulse
  alias Barkpark.Auth

  @admin_token "pulse-dashboard-admin-test-token"

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "pulse dashboard admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  test "mounts at /studio/pulse and shows the channel's durable total", %{conn: conn} do
    for _ <- 1..3,
        do:
          Pulse.record_event("test-storm", %{"hue" => 1, "x" => 0.1, "y" => 0.1, "mega" => false})

    total = Pulse.total("test-storm")

    {:ok, _view, html} = live(conn, "/admin/pulse")
    assert html =~ "Lightning Storm"
    assert html =~ "test-storm"
    assert html =~ Integer.to_string(total)
    assert html =~ "strikes ever"
  end

  test "a strike broadcast ticks the total live", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/pulse")

    BarkparkWeb.Endpoint.broadcast("pulse:test-storm", "strike", %{
      id: 999_999,
      payload: %{"hue" => 1, "x" => 0.1, "y" => 0.1, "mega" => false},
      total: 424_242
    })

    assert render(view) =~ "424,242"
  end

  test "the cost section renders live vitals and the euro estimate" do
    %{conn: conn} = %{conn: build_conn() |> init_test_session(%{"api_token" => @admin_token})}
    {:ok, _view, html} = live(conn, "/admin/pulse")
    assert html =~ "what the storm costs right now"
    assert html =~ "cost-eur"
    assert html =~ "cursor msgs"
    assert html =~ "pg_total_relation_size" or html =~ "storage"
  end

  test "the plugin contributes a Structure-desk link to the dashboard" do
    items = Barkpark.Plugins.Pulse.desk_items("production")
    assert Enum.any?(items, &(&1[:type] == :link and &1[:path] == "/admin/pulse"))
  end

  test "the Lightning Storm link survives into the desk tree under Plugins when enabled" do
    # pulse is OFF by default (ssp-w1 tiered desk): unscoped legacy builds
    # carry no pulse link; a workspace that enables pulse gets it under the
    # collapsed Plugins tier node, never the MAIN tier.
    ws = Barkpark.TenancyFixtures.create_workspace!()

    {:ok, _} =
      Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
        "pulse" => %{"enabled" => true}
      })

    tree = Barkpark.Structure.build("pulse_desk_probe", workspace_id: ws.id)

    plugins_node = Enum.find(tree.items, &(&1.id == "plugins"))
    assert plugins_node, "an enabled :plugins plugin must surface the Plugins tier node"

    node =
      plugins_node.items
      |> Enum.flat_map(fn group -> [group | group.items || []] end)
      |> Enum.find(fn n -> n.type == :plugin_link and n.filter == "/admin/pulse" end)

    assert match?(%Barkpark.Structure.Node{title: "Lightning Storm"}, node),
           "the /admin/pulse link must appear under Plugins when pulse is enabled, got #{inspect(node)}"
  end

  test "the Lightning Storm link is ABSENT from the desk by default (off-by-default)" do
    tree = Barkpark.Structure.build("pulse_desk_probe")

    flat = flatten_nodes(tree.items)

    refute Enum.any?(flat, fn n -> n.type == :plugin_link and n.filter == "/admin/pulse" end),
           "pulse declares default_enabled? false — its link must not surface unrequested"
  end

  defp flatten_nodes(items) do
    Enum.flat_map(items || [], fn n -> [n | flatten_nodes(n.items)] end)
  end

  # PROTECTIVE TEST (task-felix-w13-pulse-dashboard-mount-gate): mount/3 used to
  # run load_rows/load_vitals/safe_storage UNCONDITIONALLY — so the DISCARDED
  # disconnected render fired the pulse DB projections, doubling the queries per
  # open (the #2402 connected?-mount scar f27623fdf swept everywhere but here).
  # The loaders are now gated behind `connected?/1`. These tests count the
  # `pulse_counters` query — the unique signature of `load_rows -> Pulse.total`
  # (nothing else on this mount reads pulse_counters) — to prove 2× -> 1×: zero
  # projection queries on the dead render, exactly one per channel on connect.
  describe "disconnected mount elides the pulse projection queries" do
    test "the disconnected (dead) render runs ZERO pulse-projection queries and paints a loading skeleton",
         %{conn: conn} do
      for _ <- 1..3,
          do:
            Pulse.record_event("test-storm", %{
              "hue" => 1,
              "x" => 0.1,
              "y" => 0.1,
              "mega" => false
            })

      {conn, counter_reads} = count_pulse_counter_queries(fn -> get(conn, "/admin/pulse") end)

      body = html_response(conn, 200)
      # The dead render shows the loading skeleton, NOT the projected counters.
      assert body =~ ~s(data-test-id="pulse-loading")
      refute body =~ "strikes ever"

      # load_rows -> Pulse.total never ran on the discarded mount.
      assert counter_reads == 0,
             "the disconnected mount must issue zero pulse-projection (pulse_counters) queries, " <>
               "got #{counter_reads}"
    end

    test "the connected mount runs load_rows exactly once per channel (2x -> 1x)", %{conn: conn} do
      for _ <- 1..3,
          do:
            Pulse.record_event("test-storm", %{
              "hue" => 1,
              "x" => 0.1,
              "y" => 0.1,
              "mega" => false
            })

      # `live/2` does the disconnected render THEN connects. The disconnected leg
      # now contributes 0 pulse_counters queries (the fix), so the reads across
      # the whole flow equal exactly one per configured channel — load_rows ran
      # a single time, on connect.
      expected = map_size(Pulse.channels())

      {{:ok, _view, html}, counter_reads} =
        count_pulse_counter_queries(fn -> live(conn, "/admin/pulse") end)

      # Behavior parity: the connected view shows the same data as before.
      assert html =~ "strikes ever"

      assert counter_reads == expected,
             "load_rows must run exactly once per channel on connect, expected #{expected} " <>
               "pulse_counters queries, got #{counter_reads}"
    end
  end

  # Count Repo queries against `pulse_counters` within `fun` — the unique signature of
  # `load_rows/1` -> `Pulse.total`.
  #
  # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`. The connected mount
  # runs in a spawned LiveView process, so a `self()` filter would drop the very
  # leg being measured — but an unscoped handler is NODE-global and counts the
  # application's own background processes too, which `async: false` does not
  # fence (it fences sibling TEST processes, not the supervision tree). The
  # counter therefore reports from any process and decides ownership afterwards:
  # this test process, the LiveView pid named below, and their
  # `$callers`/`$ancestors` lineage. See `Barkpark.QueryCounterTest`.
  defp count_pulse_counter_queries(fun) do
    QueryCounter.count_source(
      fn ->
        result = fun.()

        case result do
          {:ok, %Phoenix.LiveViewTest.View{pid: pid}, _html} -> QueryCounter.own(pid)
          _ -> :ok
        end

        result
      end,
      "pulse_counters"
    )
  end
end
