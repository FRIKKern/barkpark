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
  caller. A hop that is empty, carries a port or a zone id, or does not parse
  as an address is refused, wherever it sits in the chain. The header name is matched
  without regard to case, and every copy of it is read.
  """
  @spec local_client?(Plug.Conn.t()) :: boolean()
  def local_client?(%Plug.Conn{remote_ip: peer, req_headers: headers}) do
    loopback?(peer) and
      headers
      |> Enum.filter(fn {name, _} -> String.downcase(name) == "x-forwarded-for" end)
      |> Enum.flat_map(fn {_, value} -> String.split(value, ",") end)
      |> Enum.all?(&(&1 |> String.trim() |> parse_hop() |> loopback?()))
  end

  # Bracketed IPv6 (`[::1]`) is read as the address; anything around it (a
  # port) is not, so it does not parse. Nor does a zone id (`fe80::1%en0`):
  # it names an interface on the sender's machine, not this one.
  defp parse_hop("[" <> rest) do
    case String.split_at(rest, -1) do
      {address, "]"} -> parse_hop(address)
      _ -> nil
    end
  end

  defp parse_hop(hop) do
    case not String.contains?(hop, "%") and :inet.parse_strict_address(String.to_charlist(hop)) do
      {:ok, address} -> address
      _ -> nil
    end
  end

  # IPv4 127.0.0.0/8, IPv6 ::1, and either as IPv4-mapped IPv6.
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, ab, _}), do: div(ab, 256) == 127
  defp loopback?(_), do: false
end
