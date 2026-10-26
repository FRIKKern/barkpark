defmodule BarkparkWeb.PeerProbe do
  @moduledoc """
  Has the client of a long-lived streaming response gone? (task-8c7219534ff42b88)

  A server-sent events stream learns its client left only when a write fails,
  and the first write after the client closes still succeeds (the kernel
  buffers it). A stream with nothing to send would then hold its process, its
  PubSub subscription and its cap slot until a later write.

  `closed?/1` asks the socket directly, the way Bandit itself tells a
  disconnect from a timeout: a non-blocking `recv` on the HTTP/1 connection.
  An SSE client sends nothing after its request, so `{:error, :timeout}` means
  it is still there and `{:error, :closed}` (or any other error) means it left.

  Only Bandit's HTTP/1 transport is probed. Any other adapter (HTTP/2, the
  test adapter) answers `false`, and the stream's keepalive write remains the
  fallback.
  """

  @doc "True when the connection behind `conn` is known to be closed."
  @spec closed?(Plug.Conn.t()) :: boolean()
  def closed?(%Plug.Conn{adapter: {Bandit.Adapter, %{transport: transport}}}) do
    case transport do
      %Bandit.HTTP1.Socket{socket: %ThousandIsland.Socket{} = socket} ->
        case ThousandIsland.Socket.recv(socket, 0, 0) do
          {:error, :timeout} -> false
          {:error, _reason} -> true
          {:ok, _data} -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def closed?(_conn), do: false
end
