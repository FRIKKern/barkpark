defmodule BarkparkWeb.Plugs.RequireLoopback do
  @moduledoc """
  Gate that lets a request through only when the CLIENT — not merely the TCP
  peer — is on the loopback interface (IPv4 `127.0.0.0/8` or IPv6 `::1`).
  Used by the localhost fast-path search endpoint (Barkpark Cloud P4 / Move B)
  so the lean search pipeline is only reachable by co-located callers on the
  same box.

  The gate admits a request only when it comes from this machine and every
  forwarded hop reads as this machine; anything it cannot read is refused
  (`local_client?/1`). A front proxy on the same machine must set the
  forwarded-for header itself: it dials loopback, so a request it relays
  without the header reads as a direct local caller.

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
    if local_client?(conn) do
      conn
    else
      conn
      |> send_resp(403, "")
      |> halt()
    end
  end

  @doc """
  Admits only when the TCP peer is loopback and every forwarded hop parses as
  loopback; no forwarded header from a loopback peer is the direct local
  caller. A hop is read with plain spaces and tabs trimmed, and must then be
  an address the strict parser takes as it stands, or an IPv6 address in one
  pair of brackets. Anything else is refused wherever it sits in the chain:
  an empty hop, bytes that are not valid UTF-8, a port, a zone id, an IPv4
  address in brackets, any other whitespace. The header name is matched
  without regard to case, and every copy of it is read.
  """
  @spec local_client?(Plug.Conn.t()) :: boolean()
  def local_client?(%Plug.Conn{req_headers: headers} = conn) do
    loopback?(RateLimiter.tcp_peer(conn)) and
      headers
      |> Enum.filter(fn {name, _} -> String.downcase(name, :ascii) == "x-forwarded-for" end)
      |> Enum.flat_map(fn {_, value} -> hops(value) end)
      |> Enum.all?(&(&1 |> parse_hop() |> loopback?()))
  end

  # A value that is not valid UTF-8 is read as one hop that does not parse.
  defp hops(value) do
    if String.valid?(value),
      do: value |> String.split(",") |> Enum.map(&trim_blank/1),
      else: [nil]
  end

  # Plain spaces and tabs only: any other whitespace stays, so the hop does not parse.
  defp trim_blank(hop), do: String.replace(hop, ~r/\A[ \t]+|[ \t]+\z/, "")

  # An IPv6 address in one pair of brackets (`[::1]`) is read as the address;
  # anything around the brackets (a port) or inside them that is not IPv6 does
  # not parse. Nor does a zone id (`fe80::1%en0`): it names an interface on the
  # sender's machine, not this one.
  defp parse_hop(nil), do: nil

  defp parse_hop("[" <> rest) do
    with {inner, "]"} <- String.split_at(rest, -1),
         address when tuple_size(address) == 8 <- parse_address(inner) do
      address
    else
      _ -> nil
    end
  end

  defp parse_hop(hop), do: parse_address(hop)

  # Only the characters an address is written in reach the parser, so no hop
  # can make it raise.
  defp parse_address(hop) do
    with true <- hop =~ ~r/\A[0-9A-Fa-f:.]+\z/,
         {:ok, address} <- :inet.parse_strict_address(String.to_charlist(hop)) do
      address
    else
      _ -> nil
    end
  end

  # IPv4 127.0.0.0/8, IPv6 ::1, and either as IPv4-mapped IPv6.
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, ab, _}), do: div(ab, 256) == 127
  defp loopback?(_), do: false
end
