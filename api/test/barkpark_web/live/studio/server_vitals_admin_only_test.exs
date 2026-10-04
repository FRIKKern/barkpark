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

  defp token_conn(conn, permissions) do
    raw = "vitals-#{Enum.join(permissions, "-")}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        raw,
        "vitals",
        "production",
        permissions,
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    conn |> post("/login", %{"token" => raw}) |> recycle()
  end

  test "an anonymous Studio viewer sees no host vitals", %{conn: conn} do
    {:ok, view, html} = live(conn, @studio)

    assert socket_assigns(view)[:current_user] == nil
    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  test "a member token without admin permission sees no host vitals", %{conn: conn} do
    {:ok, view, html} = conn |> token_conn(["read", "write"]) |> live(@studio)

    refute html =~ "server-vitals"
    refute render(view) =~ "server-vitals-line"
  end

  test "an instance admin still sees the host vitals", %{conn: conn} do
    {:ok, view, _html} = conn |> token_conn(["read", "write", "admin"]) |> live(@studio)

    assert render(view) =~ "server-vitals"
    assert find_live_child(view, "server-vitals")
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
