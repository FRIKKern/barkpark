defmodule BarkparkWeb.Studio.ServerVitalsAdminOnlyTest do
  @moduledoc """
  Owner ruling #30 Q5 (2026-10-03, task-1631e0fa917452d9): the Studio footer's
  host vitals (CPU, RAM, disk, load, uptime) render only for an instance admin
  — the same `instance_admin?` chrome flag the self-update banner rides, and
  the same audience `/v1/instance/metrics` admits. Before, the footer mounted
  `ServerVitalsLive` for every Studio viewer, so an anonymous demo visitor or a
  read-only share viewer saw the host's load.

  `async: false` — flips the global `:public_demo_studio` env (restored).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @studio "/w/default/p/default/d/production/studio"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, true)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)
    :ok
  end

  defp token_conn(conn, permissions, workspace_id \\ nil) do
    raw = "vitals-#{Enum.join(permissions, "-")}-#{System.unique_integer([:positive])}"
    ws_id = workspace_id || Barkpark.TenancyFixtures.default_workspace_id!()
    {:ok, token} = Auth.create_token(raw, "vitals", "production", permissions, ws_id)

    {conn |> post("/login", %{"token" => raw}) |> recycle(), token}
  end

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  test "an anonymous Studio viewer sees no host vitals", %{conn: conn} do
    {:ok, view, html} = live(conn, @studio)

    assert socket_assigns(view)[:current_user] == nil
    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  test "a member token without admin permission sees no host vitals", %{conn: conn} do
    {conn, _} = token_conn(conn, ["read", "write"])
    {:ok, view, html} = live(conn, @studio)

    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  test "an instance admin still sees the host vitals", %{conn: conn} do
    {conn, _} = token_conn(conn, ["read", "write", "admin"])
    {:ok, view, _html} = live(conn, @studio)

    assert render(view) =~ "server-vitals"
    assert find_live_child(view, "server-vitals")
  end

  # The vitals are the HOST's. An `admin` token is not the instance operator
  # just by holding the permission: the audience is the one the ops consoles
  # and `/v1/instance/metrics` admit (task-9768098607d2664c).
  test "an admin token bound to a tenant workspace sees no host vitals", %{conn: conn} do
    ws = Barkpark.TenancyFixtures.create_workspace!()
    proj = Barkpark.TenancyFixtures.create_project!(ws)
    {:ok, _} = Barkpark.Tenancy.get_or_create_dataset(proj, "production")

    {conn, _} = token_conn(conn, ["read", "write", "admin"], ws.id)
    {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio")

    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  test "with the operator allowlist armed, only the listed admin token sees them", %{conn: conn} do
    {listed_conn, listed} = token_conn(conn, ["read", "write", "admin"])
    {other_conn, _} = token_conn(conn, ["read", "write", "admin"])
    arm([listed.id])

    {:ok, view, _} = live(listed_conn, @studio)
    assert find_live_child(view, "server-vitals")

    {:ok, view, html} = live(other_conn, @studio)
    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
