defmodule Barkpark.Plugins.Pulse.DashboardLiveTest do
  @moduledoc """
  The read-only Studio dashboard for Pulse channels: it mounts under
  `/studio/pulse` (admin), shows each channel's durable total, ticks live on a
  strike broadcast, and is linked from the Structure desk via `desk_items/1`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Pulse
  alias Barkpark.Auth

  @admin_token "pulse-dashboard-admin-test-token"

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

    assert %Barkpark.Structure.Node{title: "Lightning Storm"} = node,
           "the /admin/pulse link must appear under Plugins when pulse is enabled"
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
end
