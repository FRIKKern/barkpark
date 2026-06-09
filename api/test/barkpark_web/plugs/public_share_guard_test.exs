defmodule BarkparkWeb.Plugs.PublicShareGuardTest do
  @moduledoc """
  P7 — the tunnel host-gate. Default-OFF; on a non-local Host it allows ONLY the
  public read/share GET surfaces and 404s everything else (Studio, /v1 writes +
  admin, /login, /live). Local/LAN Hosts always pass.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias BarkparkWeb.Plugs.PublicShareGuard

  @tunnel "blue-cat-123.trycloudflare.com"

  setup do
    prior = Application.get_env(:barkpark, :share_host)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, :share_host, prior),
        else: Application.delete_env(:barkpark, :share_host)
    end)

    :ok
  end

  defp call(method, path, host) do
    conn = %{conn(method, path) | host: host}
    PublicShareGuard.call(conn, [])
  end

  describe "tunnel mode OFF (no :share_host)" do
    test "pure no-op — even /studio on a tunnel host passes" do
      Application.delete_env(:barkpark, :share_host)
      refute call("GET", "/studio", @tunnel).halted
    end
  end

  describe "tunnel mode ON" do
    setup do
      Application.put_env(:barkpark, :share_host, @tunnel)
      :ok
    end

    test "LOCAL / LAN hosts pass unrestricted (even /studio)" do
      for host <- ~w(localhost 127.0.0.1 10.206.47.123 192.168.1.5 172.16.0.1 169.254.1.1) do
        refute call("GET", "/studio", host).halted, "#{host} must pass"
      end
    end

    test "non-local host: safe read/share paths pass" do
      safe = [
        "/s/abc123",
        "/papers/welcome",
        "/w/ws/p/proj/papers/x",
        "/w/ws/p/proj/v1/data/query/production/post",
        "/w/ws/p/proj/v1/data/doc/production/post/p1",
        "/w/ws/p/proj/media/files/a.png",
        "/media/files/a.png",
        "/media/renditions/x/thumb",
        "/v1/media/production/share/tok",
        "/v1/meta",
        "/v1/capabilities",
        "/assets/app.css",
        "/favicon.ico"
      ]

      for path <- safe do
        refute call("GET", path, @tunnel).halted, "#{path} must pass on the tunnel"
      end
    end

    test "non-local host: admin / write / auth paths 404" do
      blocked = [
        "/studio",
        "/studio/production",
        "/studio/settings",
        "/login",
        "/logout",
        "/v1/shares",
        "/v1/shares/links",
        "/v1/shares/tokens",
        "/v1/schemas/production",
        "/v1/webhooks/production",
        "/v1/plugins",
        "/v1/data/mutate/production",
        # flat data reads are EXCLUDED (would expose the whole Default dataset)
        "/v1/data/query/production/post",
        "/v1/media/production",
        "/api/workspaces",
        "/live/websocket",
        "/dev/dashboard"
      ]

      for path <- blocked do
        conn = call("GET", path, @tunnel)
        assert conn.halted and conn.status == 404, "#{path} must 404 on the tunnel"
      end
    end

    test "non-local host: NON-GET methods 404 even on a safe path" do
      assert call("POST", "/s/abc", @tunnel).status == 404
      assert call("DELETE", "/media/files/a.png", @tunnel).status == 404
      assert call("POST", "/w/ws/p/proj/v1/data/mutate/production", @tunnel).status == 404
    end
  end
end
