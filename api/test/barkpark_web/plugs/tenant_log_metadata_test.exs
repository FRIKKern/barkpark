defmodule BarkparkWeb.Plugs.TenantLogMetadataTest do
  @moduledoc """
  Protective coverage for the P1 tenant-log-attribution fix: after the scope is
  resolved, the tenant identity (workspace_id/workspace_slug/project_id/dataset)
  MUST reach `Logger.metadata` — otherwise a prod log line during a cross-tenant
  incident is tenant-anonymous and the blast radius is unknowable.

  These tests fail RED before the plug exists / if a future pipeline reorder
  drops the plug, and prove the field renders in the actual emitted log line
  (the config metadata allowlist), not just that it sits in the metadata map.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  require Logger

  alias BarkparkWeb.Plugs.TenantLogMetadata

  defp scoped_conn(conn) do
    conn
    |> assign(:current_workspace, %{id: "ws-abc", slug: "acme"})
    |> assign(:current_project, %{id: "pr-xyz", slug: "marketing-site"})
    |> Map.put(:path_params, %{"dataset" => "production"})
  end

  setup do
    # Start each test from a clean metadata slate (the LV process is long-lived
    # in prod, but a stale value must never mask a bug here).
    Logger.reset_metadata([])
    :ok
  end

  test "the plug stamps the resolved tenant scope into Logger.metadata", %{conn: conn} do
    conn = conn |> scoped_conn() |> TenantLogMetadata.call([])

    meta = Logger.metadata()
    assert meta[:workspace_id] == "ws-abc"
    assert meta[:workspace_slug] == "acme"
    assert meta[:project_id] == "pr-xyz"
    assert meta[:dataset] == "production"
    refute conn.halted
  end

  test "MEASUREMENT: a warning logged after the plug carries the workspace_id in the emitted line",
       %{conn: conn} do
    conn |> scoped_conn() |> TenantLogMetadata.call([])

    log =
      capture_log(fn ->
        Logger.warning("cross-tenant read leak suspected")
      end)

    # Proves tenant attribution reaches the SINK — the field is in the config
    # metadata allowlist, so it renders in the formatted line (not just the map).
    assert log =~ "workspace_id=ws-abc"
    assert log =~ "dataset=production"
    assert log =~ "cross-tenant read leak suspected"
  end

  test "an anonymous / global-scope request stamps the 'global' sentinel, never crashes", %{
    conn: conn
  } do
    # No :current_workspace assign — the flat unauthenticated / pre-backfill path.
    conn = TenantLogMetadata.call(conn, [])

    assert Logger.metadata()[:workspace_id] == "global"
    refute conn.halted

    log = capture_log(fn -> Logger.warning("anon path") end)
    assert log =~ "workspace_id=global"
  end

  test "stamp/3 (the shared LiveView entry point) stamps the same keys" do
    # The Studio LiveView calls this exact function from handle_params, so the
    # both-surfaces claim is proven without a full live mount.
    TenantLogMetadata.stamp(
      %{id: "ws-live", slug: "lv"},
      %{id: "pr-live", slug: "desk"},
      "staging"
    )

    meta = Logger.metadata()
    assert meta[:workspace_id] == "ws-live"
    assert meta[:project_id] == "pr-live"
    assert meta[:dataset] == "staging"
  end

  test "keys/0 matches the config :logger metadata allowlist (fields resolve AND render)" do
    allowlist =
      Application.get_env(:logger, :default_formatter)
      |> Keyword.fetch!(:metadata)

    for key <- TenantLogMetadata.keys() do
      assert key in allowlist,
             "#{inspect(key)} is stamped but missing from the config :logger metadata allowlist — it would resolve but never render"
    end
  end
end
