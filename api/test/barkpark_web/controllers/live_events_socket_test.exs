defmodule BarkparkWeb.LiveEventsSocketTest do
  @moduledoc """
  task-8c7219534ff42b88: a live events stream ends within seconds of its
  client closing the socket, with no writes on the dataset, so its cap slot
  frees at once. Over a real socket: the endpoint behind a Bandit listener on
  a free port, a raw `:gen_tcp` client.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}

  @dataset "live_socket_ds"
  @streams Barkpark.Realtime.LiveStreams

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "live-socket", name: "Live socket"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

    token = "live-socket-#{System.unique_integer([:positive])}"
    {:ok, row} = Auth.create_token(token, "live", @dataset, ["read"], ws.id)

    for {key, value} <- [live_events_max_streams: 2, live_events_probe_ms: 100] do
      previous = Application.get_env(:barkpark, key)
      Application.put_env(:barkpark, key, value)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, key, previous),
          else: Application.delete_env(:barkpark, key)
      end)
    end

    server = start_supervised!({Bandit, plug: BarkparkWeb.Endpoint, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, token: token, key: {:token, row.id}, port: port}
  end

  # Opens a stream over a raw socket and reads its first frame.
  defp open(port, token) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request =
      "GET /w/live-socket/p/site/v2025-02-19/data/live/events/#{@dataset} HTTP/1.1\r\n" <>
        "host: localhost\r\nauthorization: Bearer #{token}\r\naccept: text/event-stream\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    {socket, read_until(socket, ["event: welcome", "event: goaway"], "")}
  end

  defp read_until(socket, markers, acc) do
    if Enum.any?(markers, &String.contains?(acc, &1)) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_until(socket, markers, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp open_streams(key), do: length(Registry.lookup(@streams, key))

  defp wait_for(fun, ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      if fun.(), do: :ok, else: Process.sleep(50) && :wait
    end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) > deadline end)

    fun.()
  end

  test "a closed client frees its slot within seconds, with no writes", %{
    token: t,
    key: key,
    port: port
  } do
    {socket, first} = open(port, t)
    assert first =~ "event: welcome"
    assert wait_for(fn -> open_streams(key) == 1 end)

    :ok = :gen_tcp.close(socket)
    assert wait_for(fn -> open_streams(key) == 0 end), "the closed stream still holds its slot"
  end

  # The probe consumes what it reads. Bytes after an SSE request can only be a
  # pipelined request; the stream ends and closes the connection rather than
  # let Bandit read a request missing its head.
  test "bytes pipelined behind the stream end it and close the connection", %{
    token: t,
    key: key,
    port: port
  } do
    {socket, first} = open(port, t)
    assert first =~ "event: welcome"

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    assert wait_for(fn -> open_streams(key) == 0 end), "the stream kept its slot"
    assert drain_until_closed(socket) == :closed
  end

  defp drain_until_closed(socket) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, _data} -> drain_until_closed(socket)
      {:error, :closed} -> :closed
      other -> other
    end
  end

  test "a client reconnecting 25 times at the cap never meets its own ghosts", %{
    token: t,
    key: key,
    port: port
  } do
    # One stream stays open: the site is one below the cap of 2 throughout.
    {held, first} = open(port, t)
    assert first =~ "event: welcome"

    for i <- 1..25 do
      {socket, frame} = open(port, t)
      assert frame =~ "event: welcome", "reconnect #{i} got: #{inspect(frame)}"
      :ok = :gen_tcp.close(socket)
      assert wait_for(fn -> open_streams(key) == 1 end), "reconnect #{i} left a ghost"
    end

    :gen_tcp.close(held)
  end
end
