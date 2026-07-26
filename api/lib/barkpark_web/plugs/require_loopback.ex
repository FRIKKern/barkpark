defmodule BarkparkWeb.Plugs.RequireLoopback do
  @moduledoc """
  Gate that lets a request through only when the CLIENT — not merely the TCP
  peer — is on the loopback interface (IPv4 `127.0.0.0/8` or IPv6 `::1`).
  Used by the localhost fast-path search endpoint (Barkpark Cloud P4 / Move B)
  so the lean search pipeline is only reachable by co-located callers on the
  same box.

  In production the BEAM sits behind a reverse proxy (Caddy) that dials
  `localhost`, so `conn.remote_ip` is ALWAYS loopback and gating on it admits
  the entire open internet. The client is therefore resolved through
  `Barkpark.RateLimiter.client_ip/1` — the one trust boundary for
  `x-forwarded-for` (`@canonical capability:rate-limit-client-ip`): the header
  is ignored unless the peer is loopback or listed in `BARKPARK_TRUSTED_PROXIES`
  (`config :barkpark, :trusted_proxies`), and a trusted chain is walked
  right-to-left past trusted hops, so a forged `x-forwarded-for: 127.0.0.1`
  prefix is discarded in favour of the address the proxy actually appended.

  A non-loopback client is halted with 403 and no body — the surface should
  not appear to exist to anyone but the box itself.
  """
  import Plug.Conn

  alias Barkpark.RateLimiter

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if loopback?(RateLimiter.client_ip(conn)) do
      conn
    else
      conn
      |> send_resp(403, "")
      |> halt()
    end
  end

  # client_ip/1 renders the resolved client as a canonical string; parse it
  # back to an :inet tuple. Anything unparseable is NOT loopback — fail closed.
  defp loopback?(client) when is_binary(client) do
    case :inet.parse_address(String.to_charlist(client)) do
      {:ok, address} -> loopback_address?(address)
      {:error, _} -> false
    end
  end

  # IPv4 127.0.0.0/8
  defp loopback_address?({127, _, _, _}), do: true
  # IPv6 ::1
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_), do: false
end
