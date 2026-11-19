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
    {"a loopback hop between tabs", @lo, [{@xff, "\t127.0.0.1\t"}], :admitted, "127.0.0.1"},
    {"an IPv4 loopback hop in brackets", @lo, [{@xff, "[127.0.0.1]"}], :refused, "127.0.0.1"},
    {"an IPv6 loopback hop in two pairs of brackets", @lo, [{@xff, "[[::1]]"}], :refused,
     "127.0.0.1"},
    {"a loopback hop after a no-break space", @lo, [{@xff, "\u00A0127.0.0.1"}], :refused,
     "127.0.0.1"},
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
    {"a hop that is not valid UTF-8", @lo, [{@xff, <<0xFF>>}], :refused, :not_pinned},
    {"invalid bytes mid-chain", @lo, [{@xff, "127.0.0.1, " <> <<0xC3, 0x28>> <> ", ::1"}],
     :refused, :not_pinned},
    {"a hop with a NUL", @lo, [{@xff, "127.0.0.1\0"}], :refused, "127.0.0.1"},
    {"a very long unreadable value", @lo, [{@xff, String.duplicate("1", 100_000)}], :refused,
     "127.0.0.1"},
    {"a long chain of loopback hops", @lo,
     [{@xff, Enum.join(List.duplicate("127.0.0.1", 5_000), ", ")}], :admitted, "127.0.0.1"},
    {"the header many times, all loopback", @lo, List.duplicate({@xff, "::1"}, 1_000), :admitted,
     "127.0.0.1"},
    {"the header many times, one remote", @lo,
     List.duplicate({@xff, "127.0.0.1"}, 999) ++ [{@xff, "203.0.113.9"}], :refused,
     "203.0.113.9"},
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

      assert_verdict(result, unquote(verdict))
      assert_client_ip(conn, unquote(client_ip))
    end
  end

  defp assert_verdict(result, :admitted) do
    refute result.halted
    assert result.status == nil
  end

  defp assert_verdict(result, :refused) do
    assert result.halted
    assert result.status == 403
    assert result.resp_body == ""
  end

  # The rate limiter keeps its own reading; this pins it per row.
  # `:not_pinned`: bytes it does not read as text (task-ebbc5ec2f99c069b).
  defp assert_client_ip(_conn, :not_pinned), do: :ok
  defp assert_client_ip(conn, ip), do: assert(Barkpark.RateLimiter.client_ip(conn) == ip)

  # ── Whatever it is given ───────────────────────────────────────────────

  test "whatever forwarded-for it is given, the gate admits or answers an empty 403" do
    :rand.seed(:exsss, {1, 2, 3})
    pieces = ["127.0.0.1", "::1", "[::1]", "203.0.113.9", "", " ", ",", ":", "%", "[", "]", "\0"]

    for _ <- 1..2_000 do
      value =
        Enum.map_join(1..:rand.uniform(6), fn _ ->
          case :rand.uniform(3) do
            1 -> Enum.random(pieces)
            2 -> :crypto.strong_rand_bytes(:rand.uniform(8))
            3 -> Enum.random(pieces) <> ","
          end
        end)

      headers = List.duplicate({Enum.random([@xff, "X-Forwarded-For"]), value}, :rand.uniform(3))
      result = RequireLoopback.call(request(Enum.random([@lo, @relay]), headers), [])

      assert result.halted == false or (result.status == 403 and result.resp_body == ""),
             inspect(headers)

      if not result.halted, do: assert(result.status == nil)
    end
  end

  # ── The routes behind the gate ─────────────────────────────────────────

  @gate RequireLoopback

  # The modules whose compiled code calls the gate, read from their BEAM
  # imports. Only the router may; a controller that plugs it fails here.
  defp modules_calling_gate do
    for module <- Application.spec(:barkpark, :modules),
        path = :code.which(module),
        is_list(path),
        {:ok, {_, [imports: imports]}} <- [:beam_lib.chunks(path, [:imports])],
        {@gate, :call, 2} in imports,
        do: module
  end

  # The router pipelines whose compiled function calls the gate, read from the
  # router's own debug info: a nested block or a comment cannot hide one.
  defp gated_pipelines do
    path = :code.which(BarkparkWeb.Router)

    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(path, [:debug_info])

    {:ok, %{definitions: definitions}} =
      backend.debug_info(:elixir_v1, BarkparkWeb.Router, data, [])

    pipelines =
      for route <- BarkparkWeb.Router.__routes__(),
          pipe <- pipelines(route_verb(route), route.path),
          into: MapSet.new(),
          do: pipe

    for {{name, 2}, :def, _meta, clauses} <- definitions,
        name in pipelines,
        calls_gate?(clauses),
        do: name
  end

  # A clause is `{meta, args, guards, body}`, which the walk takes as a leaf,
  # so each body is walked on its own.
  defp calls_gate?(clauses) do
    Enum.any?(clauses, fn {_meta, _args, _guards, body} ->
      {_, found} = Macro.prewalk(body, false, &{&1, &2 or &1 == @gate})
      found
    end)
  end

  defp gated_routes do
    pipelines = gated_pipelines()

    for route <- BarkparkWeb.Router.__routes__(),
        verb = route_verb(route),
        Enum.any?(pipelines(verb, route.path), &(&1 in pipelines)),
        uniq: true,
        do: {verb, route.path}
  end

  # The same set counted another way: every route the matcher sends through
  # `:api_local`, read without the gate's own helpers.
  defp api_local_route_count do
    Enum.count(BarkparkWeb.Router.__routes__(), fn route ->
      verb = route_verb(route)

      case Phoenix.Router.route_info(
             BarkparkWeb.Router,
             verb,
             probe_path(route.path),
             "localhost"
           ) do
        %{pipe_through: pipes} -> :api_local in pipes
        _no_match -> false
      end
    end)
  end

  defp route_verb(route), do: route.verb |> Atom.to_string() |> String.upcase()

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

  test "only the router calls the gate, and these routes are behind it" do
    assert modules_calling_gate() == [BarkparkWeb.Router]
    assert gated_pipelines() == [:api_local]

    routes = gated_routes()
    count = api_local_route_count()
    assert count > 0
    assert length(routes) == count, "#{count} routes pipe through :api_local"

    assert Enum.sort(routes) == [
             {"GET", "/v1/data/local/search/:dataset"},
             {"POST", "/v1/internal/retire-sse"}
           ]
  end

  defp through_endpoint(verb, path, peer, headers) do
    build_conn()
    |> Map.put(:remote_ip, peer)
    |> Map.update!(:req_headers, &(&1 ++ headers))
    |> dispatch(@endpoint, String.downcase(verb), probe_path(path), %{})
  end

  test "every route behind the gate refuses a remote peer and an unreadable hop" do
    callers = [
      {{203, 0, 113, 66}, []},
      {{203, 0, 113, 66}, [{"accept", "text/html"}]},
      {@lo, [{@xff, "garbage"}]},
      {@lo, [{@xff, <<0xFF>>}]},
      {@lo, [{"accept", "text/html"}, {@xff, "203.0.113.9"}]}
    ]

    routes = gated_routes()
    count = api_local_route_count()
    assert count > 0
    assert length(routes) == count, "#{count} routes pipe through :api_local"

    for {verb, path} <- routes, {peer, headers} <- callers do
      conn = through_endpoint(verb, path, peer, headers)
      who = "#{verb} #{path} #{inspect(peer)} #{inspect(headers)}"

      assert conn.status == 403, who
      assert conn.resp_body == "", who
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"], who
      assert get_resp_header(conn, "referrer-policy") != [], who
    end
  end
end
