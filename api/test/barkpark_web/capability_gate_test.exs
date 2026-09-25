defmodule BarkparkWeb.CapabilityGateTest do
  @moduledoc """
  task-2f59ba23bcad333e: every route of Studio Chat and CycleFleet answers a
  plain 404 when its capability is off, and routes normally when it is on.

  Each case sends the SAME request twice with only `Application.put_env`
  between them. A request without a token is refused 401 or 403 by the
  route's own auth pipeline when the capability is on, so the 404 when it is
  off can only come from `BarkparkWeb.Plugs.RequireCapability`, which runs
  before auth.

  The Studio Chat LiveViews refuse to mount and redirect to `/studio`.

  `async: false` + `on_exit` restore: the capability config is node-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Capability
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup :reset_rate_limiter!

  setup do
    previous = Application.fetch_env(:barkpark, Capability)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, Capability, value)
        :error -> Application.delete_env(:barkpark, Capability)
      end
    end)

    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, workspace} = Tenancy.create_workspace(%{slug: "capgate-#{suffix}", name: "Cap gate"})
    {:ok, _project} = Tenancy.create_project(workspace, %{slug: "default", name: "Default"})

    %{ws: workspace.slug}
  end

  defp put_capabilities(kw), do: Application.put_env(:barkpark, Capability, kw)

  defp json_conn do
    scoped_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp send_req(:get, path), do: get(json_conn(), path)
  defp send_req(:post, path), do: post(json_conn(), path, "{}")
  defp send_req(:delete, path), do: delete(json_conn(), path)

  defp status(method, path), do: send_req(method, path).status

  defp chat_routes(ws) do
    [
      {:get, "/v1/chat/sessions"},
      {:get, "/v1/chat/events"},
      {:post, "/v1/chat/sessions"},
      {:get, "/v1/chat/sessions/00000000-0000-0000-0000-000000000000/events"},
      {:get, "/w/#{ws}/v1/chat-hosts/"},
      {:post, "/v1/chat-host/enroll"},
      {:post, "/v1/chat-host/heartbeat"},
      {:get, "/v1/chat-host/commands"},
      {:post, "/v1/chat/sessions/00000000-0000-0000-0000-000000000000/state"}
    ]
  end

  defp cycle_routes(ws) do
    [
      {:get, "/v1/cycles/epic-x/wave-1"},
      {:post, "/v1/cycles/epic-x/wave-1/open"},
      {:post, "/v1/cycles/epic-x/wave-1/assignments"},
      {:get, "/w/#{ws}/p/default/v1/cycles/epic-x/wave-1"},
      {:post, "/w/#{ws}/p/default/v1/cycles/epic-x/wave-1/seal"}
    ]
  end

  # {route, status with capability ON, status with it OFF}
  defp measure(routes, on_config, off_config) do
    put_capabilities(on_config)
    on = Enum.map(routes, fn {m, p} -> {m, p, status(m, p)} end)
    put_capabilities(off_config)
    Enum.map(on, fn {m, p, on_status} -> {m, p, on_status, status(m, p)} end)
  end

  describe "Studio Chat routes" do
    test "OFF answers 404 on every route; ON reaches the route's own auth", %{ws: ws} do
      rows = measure(chat_routes(ws), [studio_chat: true], studio_chat: false)

      for {m, p, on_status, off_status} <- rows do
        assert on_status in [401, 403],
               "#{m} #{p} should reach auth when Studio Chat is on, got #{on_status}"

        assert off_status == 404,
               "#{m} #{p} should 404 when Studio Chat is off, got #{off_status}"
      end
    end
  end

  describe "CycleFleet routes" do
    test "cycle_fleet OFF answers 404 on every route; ON reaches auth", %{ws: ws} do
      rows = measure(cycle_routes(ws), [cycle_fleet: true], cycle_fleet: false)

      for {m, p, on_status, off_status} <- rows do
        assert on_status in [401, 403],
               "#{m} #{p} should reach auth when CycleFleet is on, got #{on_status}"

        assert off_status == 404, "#{m} #{p} should 404 when CycleFleet is off, got #{off_status}"
      end
    end

    test "epic_fleet OFF also refuses CycleFleet, which writes the EpicFleet ledger", %{ws: ws} do
      rows = measure(cycle_routes(ws), [epic_fleet: true], epic_fleet: false)

      for {m, p, on_status, off_status} <- rows do
        assert on_status in [401, 403],
               "#{m} #{p} should reach auth when EpicFleet is on, got #{on_status}"

        assert off_status == 404, "#{m} #{p} should 404 when EpicFleet is off, got #{off_status}"
      end
    end

    test "turning Studio Chat off leaves CycleFleet routed", %{ws: ws} do
      put_capabilities(studio_chat: false)

      for {m, p} <- cycle_routes(ws) do
        assert status(m, p) in [401, 403],
               "#{m} #{p} did not reach auth with only Studio Chat off"
      end
    end
  end

  describe "Studio Chat LiveViews" do
    setup %{ws: ws} do
      ws_row = Tenancy.get_workspace_by_slug(ws)
      raw = "capgate-admin-#{System.unique_integer([:positive])}"
      {:ok, admin} = Auth.create_token(raw, "admin", "production", ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws_row.id, admin.id, "owner")

      %{raw: raw}
    end

    test "chat hosts page mounts ON and redirects OFF", %{conn: conn, ws: ws, raw: raw} do
      path = "/w/#{ws}/p/default/studio/chat-hosts"

      put_capabilities(studio_chat: true)
      assert {:ok, _view, _html} = live(as(conn, raw), path)

      put_capabilities(studio_chat: false)
      assert {:error, {:redirect, %{to: "/studio"}}} = live(as(scoped_conn(), raw), path)
    end

    test "chat page redirects OFF even with a chat provider enabled", %{
      conn: conn,
      ws: ws,
      raw: raw
    } do
      enable_fake_chat()
      path = "/w/#{ws}/p/default/studio/chat"

      put_capabilities(studio_chat: true)
      assert {:ok, _view, _html} = live(as(conn, raw), path)

      put_capabilities(studio_chat: false)
      assert {:error, {:redirect, %{to: "/studio"}}} = live(as(scoped_conn(), raw), path)
    end
  end

  defp as(conn, raw), do: init_test_session(conn, %{"api_token" => raw})

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end
end
