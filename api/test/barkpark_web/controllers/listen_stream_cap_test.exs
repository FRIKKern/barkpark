defmodule BarkparkWeb.ListenStreamCapTest do
  @moduledoc """
  task-7a9e8f31be8b7580: one credential holds at most `:listen_max_streams`
  (default 20) open listen streams from one client address and
  `:listen_max_streams_per_credential` (default 100) in all, as live.events.
  Over a cap the answer is one `disconnect` frame and the response ends; a
  closed stream frees its slot. Listen and live.events count apart.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}

  @dataset "listen_cap_ds"
  @path "/w/listen-cap/p/site/v2025-02-19/data/listen/#{@dataset}"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "listen-cap", name: "Listen cap"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

    token = "listen-cap-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "listen cap", @dataset, ["read"], ws.id)

    for {key, value} <- [listen_max_streams: 2, listen_max_streams_per_credential: 3] do
      previous = Application.get_env(:barkpark, key)
      Application.put_env(:barkpark, key, value)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, key, previous),
          else: Application.delete_env(:barkpark, key)
      end)
    end

    %{token: token}
  end

  defp open_stream(token, ip, path \\ @path) do
    Task.async(fn ->
      %{scoped_conn() | remote_ip: ip}
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "text/event-stream")
      |> get(path)
    end)
  end

  defp events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^event: (\S+)$/m, block) do
        [_, event] ->
          data =
            case Regex.run(~r/^data: (.*)$/m, block) do
              [_, json] -> Jason.decode!(json)
              _ -> nil
            end

          [{event, data}]

        _ ->
          []
      end
    end)
  end

  defp close_stream(task) do
    send(task.pid, :retire)
    events(Task.await(task, 5_000).resp_body)
  end

  defp refused(task), do: events(Task.await(task, 5_000).resp_body)

  @a {10, 0, 0, 1}
  @b {10, 0, 0, 2}
  @c {10, 0, 0, 3}

  test "per address a stream opens up to the cap and the next is refused; another address opens",
       %{token: t} do
    [a1, a2] = for _ <- 1..2, do: open_stream(t, @a)
    Process.sleep(200)

    # The third from the same address: one disconnect frame, and the response ends at once.
    assert [{"disconnect", %{"reason" => reason}}] = open_stream(t, @a) |> refused()
    assert reason =~ "too many open listen streams for this credential from this address (2)"

    # live.events counts its own streams: the same credential and address still open one.
    live = open_stream(t, @a, "/w/listen-cap/p/site/v2025-02-19/data/live/events/#{@dataset}")

    # Another address opens: a shared credential (CI shards, a studio per server) is not cut off.
    b1 = open_stream(t, @b)
    Process.sleep(200)

    # Three in all is the credential's backstop: a fourth address is refused.
    assert [{"disconnect", %{"reason" => backstop}}] = open_stream(t, @c) |> refused()
    assert backstop =~ "too many open listen streams for this credential (3)"

    # Closing one frees its slot for the next.
    for task <- [live, a1], do: assert([{"welcome", _} | _] = close_stream(task))
    Process.sleep(100)
    a3 = open_stream(t, @a)
    Process.sleep(200)

    for task <- [a2, b1, a3], do: assert([{"welcome", _} | _] = close_stream(task))
  end
end
