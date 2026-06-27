defmodule BarkparkWeb.Plugs.RequireLoopback do
  @moduledoc """
  Gate that lets a request through only when it originated on the loopback
  interface — IPv4 `127.0.0.0/8` or IPv6 `::1`. Used by the localhost
  fast-path search endpoint (Barkpark Cloud P4 / Move B) so the lean search
  pipeline can ONLY be reached from co-located Next.js sites on the same box,
  never from the open internet.

  A non-loopback caller is halted with 403 and no body — the surface should
  not appear to exist to anyone but the box itself.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> send_resp(403, "")
      |> halt()
    end
  end

  # IPv4 127.0.0.0/8
  defp loopback?({127, _, _, _}), do: true
  # IPv6 ::1
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
