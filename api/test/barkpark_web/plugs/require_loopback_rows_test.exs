defmodule BarkparkWeb.Plugs.RequireLoopbackRowsTest do
  @moduledoc """
  The loopback gate admits a request only when it comes from this machine and
  every forwarded hop reads as this machine; anything it cannot read is
  refused. One row per forwarded-for shape, each with the gate's verdict and
  the address `RateLimiter.client_ip/1` keys its bucket by (the gate has its
  own reading; the rate limiter's stays as it is).

  The routes behind the gate are read off the router, and each one refuses a
  caller from another machine and an unreadable hop.

  `async: false`: the rows run with a trusted relay in the global
  `:trusted_proxies` config, which `client_ip/1` reads.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  setup :reset_rate_limiter!

  alias BarkparkWeb.Plugs.RequireLoopback

  @relay {198, 51, 100, 55}
  @lo {127, 0, 0, 1}
  @xff "x-forwarded-for"

  # {shape, peer, headers, gate verdict, client_ip}
  @rows [
    {"no forwarded header", @lo, [], :admitted, "127.0.0.1"},
    {"a loopback hop", @lo, [{@xff, "127.0.0.1"}], :admitted, "127.0.0.1"},
    {"an IPv6 loopback hop", @lo, [{@xff, "::1"}], :admitted, "127.0.0.1"},
    {"an IPv4-mapped loopback hop", @lo, [{@xff, "::ffff:127.0.0.1"}], :admitted, "127.0.0.1"},
    {"a bracketed loopback hop", @lo, [{@xff, "[::1]"}], :admitted, "127.0.0.1"},
    {"two headers, both loopback", @lo, [{@xff, "127.0.0.1"}, {@xff, "::1"}], :admitted,
     "127.0.0.1"},
    {"an unreadable hop", @lo, [{@xff, "garbage"}], :refused, "127.0.0.1"},
    {"an empty header", @lo, [{@xff, ""}], :refused, "127.0.0.1"},
    {"a header of empty hops", @lo, [{@xff, " , "}], :refused, "127.0.0.1"},
    {"a loopback hop the front appended a remote hop to", @lo, [{@xff, "127.0.0.1, 203.0.113.9"}],
     :refused, "203.0.113.9"},
    {"a remote hop before a loopback hop", @lo, [{@xff, "203.0.113.9, 127.0.0.1"}], :refused,
     "203.0.113.9"},
    {"an unreadable hop before a remote hop", @lo, [{@xff, "garbage, 203.0.113.9"}], :refused,
     "203.0.113.9"},
    {"a remote hop before an unreadable hop", @lo, [{@xff, "203.0.113.9, garbage"}], :refused,
     "127.0.0.1"},
    {"two headers, loopback then remote", @lo, [{@xff, "127.0.0.1"}, {@xff, "203.0.113.9"}],
     :refused, "203.0.113.9"},
    {"a mixed-case header name with a remote hop", @lo, [{"X-Forwarded-For", "203.0.113.9"}],
     :refused, "127.0.0.1"},
    {"a mixed-case header name with an unreadable hop", @lo, [{"X-Forwarded-For", "garbage"}],
     :refused, "127.0.0.1"},
    {"an IPv6 remote hop", @lo, [{@xff, "2001:db8::1"}], :refused, "2001:db8::1"},
    {"an IPv4-mapped remote hop", @lo, [{@xff, "::ffff:203.0.113.9"}], :refused, "203.0.113.9"},
    {"a loopback hop with a port", @lo, [{@xff, "127.0.0.1:8080"}], :refused, "127.0.0.1"},
    {"a remote hop with a port", @lo, [{@xff, "203.0.113.9:443"}], :refused, "127.0.0.1"},
    {"a bracketed remote hop with a port", @lo, [{@xff, "[2001:db8::1]:443"}], :refused,
     "127.0.0.1"},
    {"a link-local hop with a zone id", @lo, [{@xff, "fe80::1%en0"}], :refused, "fe80::1"},
    {"a loopback hop with a zone id", @lo, [{@xff, "::1%lo0"}], :refused, "127.0.0.1"},
    {"a trusted relay with an unreadable hop", @relay, [{@xff, "unknown"}], :refused,
     "198.51.100.55"},
    {"a trusted relay with a remote hop", @relay, [{@xff, "203.0.113.9"}], :refused,
     "203.0.113.9"},
    {"a trusted relay with a loopback hop", @relay, [{@xff, "127.0.0.1"}], :refused,
     "198.51.100.55"},
    {"a remote peer with a loopback hop", {203, 0, 113, 66}, [{@xff, "127.0.0.1"}], :refused,
     "203.0.113.66"},
    {"a remote peer with no header", {203, 0, 113, 66}, [], :refused, "203.0.113.66"}
  ]

  setup do
    original = Application.get_env(:barkpark, :trusted_proxies)
    Application.put_env(:barkpark, :trusted_proxies, [@relay])
    on_exit(fn -> Application.put_env(:barkpark, :trusted_proxies, original || []) end)
    :ok
  end

  defp request(peer, headers) do
    conn = %{Plug.Test.conn(:get, "/", nil) | remote_ip: peer}
    %{conn | req_headers: conn.req_headers ++ headers}
  end

  for {shape, peer, headers, verdict, client_ip} <- @rows do
    @tag row: shape
    test "#{shape}: #{verdict}, keyed as #{client_ip}" do
      conn = request(unquote(Macro.escape(peer)), unquote(Macro.escape(headers)))
      result = RequireLoopback.call(conn, RequireLoopback.init([]))

      case unquote(verdict) do
        :admitted ->
          refute result.halted
          assert result.status == nil

        :refused ->
          assert result.halted
          assert result.status == 403
          assert result.resp_body == ""
      end

      assert Barkpark.RateLimiter.client_ip(conn) == unquote(client_ip)
    end
  end

  # ── The routes behind the gate ─────────────────────────────────────────

  @router_source Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)

  # The pipelines whose body plugs the gate, read from the router's source.
  defp gated_pipelines do
    ~r/^\s*pipeline\(?\s*:(\w+)\)?\s+do\n(.*?)^\s*end\b/ms
    |> Regex.scan(File.read!(@router_source), capture: :all_but_first)
    |> Enum.filter(fn [_name, body] -> body =~ "RequireLoopback" end)
    |> Enum.map(fn [name, _body] -> String.to_atom(name) end)
  end

  defp gated_routes do
    pipelines = gated_pipelines()

    for route <- BarkparkWeb.Router.__routes__(),
        verb = route.verb |> Atom.to_string() |> String.upcase(),
        Enum.any?(pipelines(verb, route.path), &(&1 in pipelines)),
        uniq: true,
        do: {verb, route.path}
  end

  # The route's pipelines, read off the real matcher. A probe that lands on
  # another route fails, so a shadowed path cannot drop out of the list.
  defp pipelines(verb, path) do
    case Phoenix.Router.route_info(BarkparkWeb.Router, verb, probe_path(path), "localhost") do
      %{pipe_through: pipes, route: ^path} -> pipes
      other -> flunk("#{verb} #{path} probed to #{inspect(other)}")
    end
  end

  defp probe_path(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _ -> "zzgateprobezz"
      "*" <> _ -> "zzgateprobezz"
      segment -> segment
    end)
    |> Enum.join("/")
  end

  test "the routes behind the gate are these" do
    assert gated_pipelines() == [:api_local]

    assert Enum.sort(gated_routes()) == [
             {"GET", "/v1/data/local/search/:dataset"},
             {"POST", "/v1/internal/retire-sse"}
           ]
  end

  test "every route behind the gate refuses a remote peer and an unreadable hop" do
    for {verb, path} <- gated_routes(),
        {peer, headers} <- [{{203, 0, 113, 66}, []}, {@lo, [{@xff, "garbage"}]}] do
      conn =
        build_conn()
        |> Map.put(:remote_ip, peer)
        |> Map.update!(:req_headers, &(&1 ++ headers))
        |> dispatch(@endpoint, String.downcase(verb), probe_path(path), %{})

      assert conn.status == 403, "#{verb} #{path} #{inspect(headers)}"
      assert conn.resp_body == ""
    end
  end
end
