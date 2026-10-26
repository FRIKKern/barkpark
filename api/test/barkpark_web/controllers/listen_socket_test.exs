defmodule BarkparkWeb.ListenSocketTest do
  @moduledoc """
  task-091e648503fd0896: a `/data/listen` stream ends within seconds of its
  client closing the socket, with no writes on the dataset and long before its
  30 s keepalive, so its process and PubSub subscription go at once. Over a
  real socket: the endpoint behind a Bandit listener on a free port, a raw
  `:gen_tcp` client.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}

  @dataset "listen_socket_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "listen-socket", name: "Listen socket"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

    token = "listen-socket-#{System.unique_integer([:positive])}"
    {:ok, _row} = Auth.create_token(token, "listen", @dataset, ["read"], ws.id)

    previous = Application.get_env(:barkpark, :listen_probe_ms)
    Application.put_env(:barkpark, :listen_probe_ms, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :listen_probe_ms, previous),
        else: Application.delete_env(:barkpark, :listen_probe_ms)
    end)

    server = start_supervised!({Bandit, plug: BarkparkWeb.Endpoint, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, token: token, port: port, topic: "documents:ws:#{ws.id}:#{@dataset}"}
  end

  defp open(port, token) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request =
      "GET /w/listen-socket/p/site/v2025-02-19/data/listen/#{@dataset} HTTP/1.1\r\n" <>
        "host: localhost\r\nauthorization: Bearer #{token}\r\naccept: text/event-stream\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    {socket, read_until(socket, "event: welcome", "")}
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_until(socket, marker, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp subscribers(topic), do: length(Registry.lookup(Barkpark.PubSub, topic))

  defp wait_for(fun, ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn -> if fun.(), do: :ok, else: Process.sleep(50) && :wait end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) > deadline end)

    fun.()
  end

  test "a closed client ends its stream within seconds, with no writes", %{
    token: t,
    port: port,
    topic: topic
  } do
    {socket, first} = open(port, t)
    assert first =~ "event: welcome"
    assert wait_for(fn -> subscribers(topic) == 1 end)

    :ok = :gen_tcp.close(socket)
    assert wait_for(fn -> subscribers(topic) == 0 end), "the closed stream is still subscribed"
  end

  test "bytes pipelined behind the stream end it and close the connection", %{
    token: t,
    port: port,
    topic: topic
  } do
    {socket, first} = open(port, t)
    assert first =~ "event: welcome"

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    assert wait_for(fn -> subscribers(topic) == 0 end), "the stream is still subscribed"
    assert drain_until_closed(socket) == :closed
  end

  defp drain_until_closed(socket) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, _data} -> drain_until_closed(socket)
      {:error, :closed} -> :closed
      other -> other
    end
  end
end
