defmodule BarkparkWeb.LiveSocketClientIpTest do
  @moduledoc """
  Gate B, criterion 0 (am-w2-s6-gate-b-socket-hooks): the `/live` socket carries
  the client's address, and the connect_info-shaped `client_ip` resolution keeps
  the ONE canonical trust walk (`Barkpark.RateLimiter.client_ip/1`,
  `@canonical capability:rate-limit-client-ip`) rather than solving it twice.

  The connect_info resolver under test is `Barkpark.Quiz.SpawnBudget.principal/1`.
  It is the variant a LiveView reaches today, and it narrows a connect_info map
  to the two fields the canonical resolver reads (`:peer_data` -> `remote_ip`,
  `:x_headers` -> `req_headers`). Every case is asserted against the CANONICAL
  resolver's own answer for the equivalent conn, so the two can never drift
  apart unnoticed. The literal expected address is there only to keep the
  comparison from being vacuous.
  """
  # `async: false` + the reset: this file names Barkpark.RateLimiter, and
  # RateLimiterAsyncIsolationTest holds every such file to the named-table rule
  # even though these assertions only call the pure `client_ip/1` resolver.
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox
  setup :reset_rate_limiter!

  alias Barkpark.Quiz.SpawnBudget
  alias Barkpark.RateLimiter

  describe "the /live socket declares the client-address connect_info" do
    test "websocket AND longpoll carry :peer_data and :x_headers" do
      {"/live", Phoenix.LiveView.Socket, opts} =
        Enum.find(BarkparkWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

      for transport <- [:websocket, :longpoll] do
        info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)

        assert :peer_data in info,
               "#{transport} must declare :peer_data — without it a LiveView cannot see the client IP"

        assert :x_headers in info,
               "#{transport} must declare :x_headers — without it a proxied client reads as the proxy"
      end
    end
  end

  describe "the connect_info variant preserves the canonical trust walk" do
    # {peer, x-forwarded-for, the address the canonical walk must yield}
    @cases [
      # trusted front (Caddy on loopback) -> the forwarded client
      {{127, 0, 0, 1}, "203.0.113.5", "203.0.113.5"},
      # trusted IPv6 loopback front
      {{0, 0, 0, 0, 0, 0, 0, 1}, "203.0.113.6", "203.0.113.6"},
      # trusted front, client-supplied spoof prefix -> RIGHTMOST untrusted hop
      {{127, 0, 0, 1}, "1.1.1.1, 203.0.113.7", "203.0.113.7"},
      # UNTRUSTED peer -> the header is ignored entirely; the peer is the client
      {{198, 51, 100, 4}, "9.9.9.9", "198.51.100.4"},
      # untrusted peer, no header
      {{198, 51, 100, 8}, nil, "198.51.100.8"}
    ]

    for {{peer, xff, expected}, i} <- Enum.with_index(@cases) do
      @peer peer
      @xff xff
      @expected expected
      test "case #{i}: peer #{inspect(peer)} xff #{inspect(xff)} -> #{expected}" do
        headers = if @xff, do: [{"x-forwarded-for", @xff}], else: []
        connect_info = %{peer_data: %{address: @peer, port: 4000}, x_headers: headers}

        canonical = RateLimiter.client_ip(%Plug.Conn{remote_ip: @peer, req_headers: headers})

        assert canonical == @expected
        assert SpawnBudget.principal(connect_info) == {:client_ip, canonical}
      end
    end
  end
end
