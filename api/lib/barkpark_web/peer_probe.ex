defmodule BarkparkWeb.PeerProbe do
  @moduledoc """
  Has the client of a long-lived streaming response gone? (task-8c7219534ff42b88)

  A server-sent events stream learns its client left only when a write fails,
  and the first write after the client closes still succeeds (the kernel
  buffers it). A stream with nothing to send would then hold its process, its
  PubSub subscription and its cap slot until a later write.

  `status/1` asks the socket directly, the way Bandit itself tells a
  disconnect from a timeout: a non-blocking `recv` on the HTTP/1 connection.
  The caller probes only once its response is streaming (after
  `send_chunked/2`), when the request has been read in full.

    * `:open` — `{:error, :timeout}`: nothing to read, the client is there.
    * `:closed` — any other error: the client has gone.
    * `:pipelined` — bytes arrived. An SSE client (EventSource, `@sanity/client`)
      sends nothing after its request, so these can only be a request
      pipelined behind an endless response. `recv` has consumed them, so the
      connection must not serve another request: the caller ends its stream
      and calls `close/1`, and the client retries on a new connection, as
      HTTP/1.1 clients do for a pipelined request a server closes on.

  Only Bandit's HTTP/1 transport is probed. Any other adapter (HTTP/2, the
  test adapter) answers `:open`, and the stream's keepalive write remains the
  fallback.
  """

  @doc "Whether the client behind a streaming `conn` is still there."
  @spec status(Plug.Conn.t()) :: :open | :closed | :pipelined
  def status(conn) do
    case socket(conn) do
      nil ->
        :open

      socket ->
        case ThousandIsland.Socket.recv(socket, 0, 0) do
          {:error, :timeout} -> :open
          {:error, _reason} -> :closed
          {:ok, _data} -> :pipelined
        end
    end
  rescue
    _ -> :open
  end

  @doc "Closes the connection behind `conn`, so it serves no further request."
  @spec close(Plug.Conn.t()) :: :ok
  def close(conn) do
    case socket(conn) do
      nil -> :ok
      socket -> ThousandIsland.Socket.close(socket)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp socket(%Plug.Conn{adapter: {Bandit.Adapter, %{transport: transport}}}) do
    case transport do
      %Bandit.HTTP1.Socket{socket: %ThousandIsland.Socket{} = socket} -> socket
      _ -> nil
    end
  end

  defp socket(_conn), do: nil
end
