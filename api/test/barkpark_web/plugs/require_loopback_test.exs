defmodule BarkparkWeb.Plugs.RequireLoopbackTest do
  @moduledoc """
  The trust boundary of the localhost fast-path search route
  (`/v1/data/local/search/:dataset`), whose ENTIRE authz is this plug.

  In production the BEAM sits behind Caddy, which dials `localhost` — so
  `conn.remote_ip` is loopback for EVERY request, including ones from the open
  internet. The inherited gate read exactly that raw peer, which meant the
  route served drafts and private types to anyone, tokenless (proven live
  2026-07-26). The fix gates on `Barkpark.RateLimiter.client_ip/1`, the one
  canonical `x-forwarded-for` resolver.

  PROTECTIVE, not vacuous — substitute the old read
  (`loopback?(conn.remote_ip)` on the raw tuple) and "a public caller relayed
  by the co-located proxy is 403ed" plus both forged-header tests go RED: the
  loopback peer admits everyone the proxy fronts.

  `async: false`: one test moves the global `:trusted_proxies` config, which
  `client_ip/1` reads.
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  import Plug.Test, only: [conn: 3]

  alias BarkparkWeb.Plugs.RequireLoopback

  # A public, routable address standing in for an internet caller.
  @attacker "203.0.113.66"

  setup do
    original = Application.get_env(:barkpark, :trusted_proxies)
    on_exit(fn -> Application.put_env(:barkpark, :trusted_proxies, original || []) end)
    :ok
  end

  defp request(peer, forwarded_values \\ []) do
    Enum.reduce(forwarded_values, %{conn(:get, "/", nil) | remote_ip: peer}, fn value, acc ->
      Plug.Conn.put_req_header(acc, "x-forwarded-for", value)
    end)
  end

  # put_req_header REPLACES, so a genuinely repeated header (caller sends one
  # line, Caddy appends its own) is built here.
  defp request_with_repeated_header(peer, values) do
    %{conn(:get, "/", nil) | remote_ip: peer}
    |> Map.update!(:req_headers, fn headers ->
      headers ++ Enum.map(values, &{"x-forwarded-for", &1})
    end)
  end

  defp run(conn), do: RequireLoopback.call(conn, RequireLoopback.init([]))

  defp assert_admitted(conn) do
    result = run(conn)
    refute result.halted
    assert result.status == nil
  end

  defp assert_refused(conn) do
    result = run(conn)
    assert result.halted
    assert result.status == 403
    assert result.resp_body == ""
  end

  describe "co-located caller (no proxy chain)" do
    test "an IPv4 loopback peer with no forwarded header is ADMITTED" do
      assert_admitted(request({127, 0, 0, 1}))
    end

    test "an IPv6 ::1 peer is ADMITTED" do
      assert_admitted(request({0, 0, 0, 0, 0, 0, 0, 1}))
    end

    test "an IPv4-mapped IPv6 loopback peer (dual-stack listener) is ADMITTED" do
      assert_admitted(request({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}))
    end
  end

  describe "public caller relayed by the co-located proxy" do
    test "a public caller relayed by the co-located proxy is 403ed" do
      # Caddy dials localhost (peer = loopback) and appends the caller's
      # real address — the raw-peer read admitted exactly this request.
      assert_refused(request({127, 0, 0, 1}, [@attacker]))
    end
  end

  describe "forged x-forwarded-for from a public caller" do
    test "a forged loopback prefix behind the proxy is 403ed, not admitted" do
      # Caller sends 'x-forwarded-for: 127.0.0.1'; Caddy APPENDS the address it
      # actually saw. Walking right-to-left lands on the attacker, so the
      # forgery buys nothing. A naive first-hop read fails exactly here.
      assert_refused(request({127, 0, 0, 1}, ["127.0.0.1, #{@attacker}"]))
    end

    test "a forged loopback prefix as a SEPARATE repeated header is 403ed" do
      assert_refused(request_with_repeated_header({127, 0, 0, 1}, ["127.0.0.1", @attacker]))
    end
  end

  describe "direct-to-BEAM attacker" do
    test "a non-loopback peer is 403ed and its forged header is IGNORED" do
      assert_refused(request({203, 0, 113, 66}, ["127.0.0.1"]))
    end

    test "a non-loopback peer with no header at all is 403ed" do
      assert_refused(request({203, 0, 113, 66}))
    end
  end

  describe "operator-listed trusted front (BARKPARK_TRUSTED_PROXIES)" do
    test "a public caller relayed by a listed non-loopback front is still 403ed" do
      Application.put_env(:barkpark, :trusted_proxies, [{198, 51, 100, 55}])
      assert_refused(request({198, 51, 100, 55}, [@attacker]))
    end
  end
end
