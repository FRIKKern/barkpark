defmodule Barkpark.TestSupport.BlackHole do
  @moduledoc """
  A TCP listener that ACCEPTS a request, reads its bytes, and then never
  answers — the "remote took the write, the response was lost" condition.

  This is the only faithful stub for the timed-out-but-accepted defect: a
  sleeping Bypass plug races test teardown (the plug is still asleep when
  Bypass shuts down, surfacing as `(exit) shutdown`), and `Bypass.down/1`
  produces `:econnrefused` — a request that was never sent, i.e. the exact
  case a retry IS allowed to replay.

  `start/0` returns `{base_url, counter_fun}` where `counter_fun.()` is the
  number of complete requests that reached the socket.
  """

  @doc "Start the listener. Returns `{base_url, fn -> hits end}`."
  def start do
    parent = self()

    acceptor =
      spawn(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(parent, {:black_hole_port, self(), port})
        accept_loop(listen, parent)
      end)

    port =
      receive do
        {:black_hole_port, ^acceptor, p} -> p
      after
        5_000 -> raise "black hole listener did not start"
      end

    {acceptor, "http://127.0.0.1:#{port}",
     fn ->
       # Drain every :black_hole_hit delivered so far into a count. Requests
       # are reported by message, so a count taken after the client returned
       # cannot miss a hit the client itself already produced.
       drain(0)
     end}
  end

  @doc "Kill the listener and every held connection."
  def stop(acceptor), do: Process.exit(acceptor, :kill)

  defp drain(n) do
    receive do
      :black_hole_hit -> drain(n + 1)
    after
      0 -> n
    end
  end

  defp accept_loop(listen, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        handler = spawn_link(fn -> hold(sock, parent) end)
        :ok = :gen_tcp.controlling_process(sock, handler)
        send(handler, :owned)
        accept_loop(listen, parent)

      {:error, _} ->
        :ok
    end
  end

  defp hold(sock, parent) do
    receive do
      :owned -> :ok
    after
      5_000 -> :ok
    end

    # Read until the request head is complete, so a hit is only counted once
    # the client has actually handed the request over.
    case read_head(sock, "") do
      :ok -> send(parent, :black_hole_hit)
      :error -> :ok
    end

    # Never respond. Hold the socket open so the client sees a RECEIVE
    # timeout, not a closed connection.
    Process.sleep(:infinity)
  end

  defp read_head(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, bytes} ->
        acc = acc <> bytes
        if String.contains?(acc, "\r\n\r\n"), do: :ok, else: read_head(sock, acc)

      {:error, _} ->
        :error
    end
  end
end
