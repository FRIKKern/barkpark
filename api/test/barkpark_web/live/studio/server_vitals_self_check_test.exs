defmodule BarkparkWeb.Studio.ServerVitalsSelfCheckTest do
  @moduledoc """
  task-6819027be1f93642: `ServerVitalsLive` is a sticky child LiveView, so it
  joins on its own signed session. The layout's `host_vitals?` flag only
  decides whether the footer renders it; the view must ask the same question
  itself, at mount and on every tick. These tests mount the view directly, the
  way a saved session would, with no layout in front of it.

  `async: false`: arms the global operator allowlist (restored).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias BarkparkWeb.ServerVitalsLive

  defp admin_token(workspace_id \\ nil) do
    raw = "vitals-self-#{System.unique_integer([:positive])}"
    ws_id = workspace_id || Barkpark.TenancyFixtures.default_workspace_id!()
    {:ok, token} = Auth.create_token(raw, "vitals", "production", ~w(read write admin), ws_id)
    {raw, token}
  end

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  defp mount_vitals(conn, session) do
    {:ok, view, html} = live_isolated(conn, ServerVitalsLive, session: session)
    {view, html}
  end

  defp tick(view) do
    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: Barkpark.HostVitals.Sampler.topic(),
      event: "tick",
      payload: Barkpark.HostVitals.Sampler.snapshot()
    })

    render(view)
  end

  test "an admin token bound to a tenant workspace gets no vitals from a direct mount",
       %{conn: conn} do
    ws = Barkpark.TenancyFixtures.create_workspace!()
    {raw, _} = admin_token(ws.id)

    {view, html} = mount_vitals(conn, %{"api_token" => raw})

    refute html =~ "server-vitals-line"
    refute tick(view) =~ "server-vitals-line"
  end

  test "the instance operator still gets the vitals, at mount and on a tick", %{conn: conn} do
    {raw, _} = admin_token()

    {view, html} = mount_vitals(conn, %{"api_token" => raw})

    assert html =~ "server-vitals-line"
    assert tick(view) =~ "server-vitals-line"
  end

  test "a session with no credential, or an unusable one, gets no vitals", %{conn: conn} do
    for session <- [%{}, %{"api_token" => 123}, %{"api_token" => "no-such-token"}] do
      {view, html} = mount_vitals(conn, session)

      refute html =~ "server-vitals-line"
      refute tick(view) =~ "server-vitals-line"
    end
  end

  test "a tick after the allowlist stops naming the token stops the vitals", %{conn: conn} do
    {raw, _} = admin_token()
    {_, other} = admin_token()

    {view, html} = mount_vitals(conn, %{"api_token" => raw})
    assert html =~ "server-vitals-line"

    arm([other.id])

    refute tick(view) =~ "server-vitals-line"
    # ...and it stays stopped: the view left the topic.
    refute tick(view) =~ "server-vitals-line"
  end
end
