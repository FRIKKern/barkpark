defmodule BarkparkWeb.Integration.PresenceApiTest do
  @moduledoc """
  task-32b73e85f89d4be7 — editor presence for non-LiveView clients.

  Two SSE streams join one document's room; one moves its focus with the POST;
  the other stream carries that focus, and the room broadcast lands within the
  300 ms budget. When a stream ends its entry leaves the room.

  Drive: each stream runs the real route inside a `Task` (the task process is
  the tracked connection), and `:sse_overloaded` ends its loop and hands back
  the body, as in `listen_server_filter_test.exs`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.PresenceState

  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    ws = create_workspace!("presence-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "presence-p-#{System.unique_integer([:positive])}")

    raw = "presence-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "parity-proxy", @ds, ["read", "write"], ws.id)
    other = "presence-other-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(other, "someone-else", @ds, ["read", "write"], ws.id)
    viewer = "presence-viewer-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(viewer, "viewer", @ds, ["read"], ws.id)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer " <> raw),
     other_conn: put_req_header(scoped_conn(), "authorization", "Bearer " <> other),
     viewer_conn: put_req_header(scoped_conn(), "authorization", "Bearer " <> viewer),
     base: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/presence/#{@ds}",
     topic: PresenceState.topic(ws.id, proj.id, @ds)}
  end

  defp open(conn, base, params), do: Task.async(fn -> get(conn, base, params) end)

  defp close(task) do
    send(task.pid, :sse_overloaded)
    Task.await(task, 10_000)
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp keys(topic), do: topic |> Presence.list() |> Map.keys() |> Enum.sort()

  defp frames(%{status: 200, resp_body: body}, event) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "event: #{event}\n"))
    |> Enum.map(fn f ->
      f |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
    end)
  end

  defp focus(conn, base, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(base <> "/focus", Jason.encode!(body))
  end

  test "two clients see each other's document and field focus within 300 ms", ctx do
    a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-1", "name" => "Ann", "documentId" => "p1"})
    b = open(ctx.conn, ctx.base, %{"sessionId" => "bob-1", "name" => "Bob", "documentId" => "p1"})
    wait_for(fn -> keys(ctx.topic) == ["api:ann-1", "api:bob-1"] end)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, ctx.topic)
    started = System.monotonic_time(:millisecond)

    resp =
      focus(ctx.conn, ctx.base, %{
        "sessionId" => "ann-1",
        "documentId" => "p1",
        "field" => "seo.metaTitle"
      })

    assert resp.status == 200

    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 300
    assert System.monotonic_time(:millisecond) - started < 300

    wait_for(fn ->
      match?(%{metas: [%{field: "seo.metaTitle"}]}, Presence.get_by_key(ctx.topic, "api:ann-1"))
    end)

    bob_body = close(b)
    close(a)

    assert [%{"sessionId" => "bob-1"}] = frames(bob_body, "session")

    assert Enum.any?(frames(bob_body, "presence"), fn %{"presences" => list} ->
             Enum.any?(
               list,
               &(&1 == %{
                   "sessionId" => "ann-1",
                   "name" => "Ann",
                   "documentId" => "p1",
                   "field" => "seo.metaTitle",
                   "client" => "api",
                   "color" => PresenceState.pick_color("ann-1")
                 })
             )
           end)
  end

  test "an entry leaves the room when its stream ends", ctx do
    a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-2", "name" => "Ann"})
    b = open(ctx.conn, ctx.base, %{"sessionId" => "bob-2", "name" => "Bob"})
    wait_for(fn -> keys(ctx.topic) == ["api:ann-2", "api:bob-2"] end)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, ctx.topic)
    close(a)
    wait_for(fn -> keys(ctx.topic) == ["api:bob-2"] end)

    # B is told: the leave diff reaches every room subscriber. Let B's own copy
    # be handled before :sse_overloaded joins its mailbox.
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
                   when is_map_key(leaves, "api:ann-2"),
                   1_000

    Process.sleep(100)

    last = ctx.conn |> then(fn _ -> close(b) end) |> frames("presence") |> List.last()
    assert Enum.map(last["presences"], & &1["sessionId"]) == ["bob-2"]
    wait_for(fn -> keys(ctx.topic) == [] end)
  end

  test "focus is refused for a session that is not live, or not this token's", ctx do
    assert focus(ctx.conn, ctx.base, %{"sessionId" => "nobody"}).status == 404

    a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-3"})
    wait_for(fn -> keys(ctx.topic) == ["api:ann-3"] end)

    assert focus(ctx.other_conn, ctx.base, %{"sessionId" => "ann-3", "field" => "x"}).status ==
             404

    assert focus(ctx.conn, ctx.base, %{"sessionId" => "ann-3", "field" => "x"}).status == 200
    close(a)
  end

  test "a read token can stream (and is seen) but moving focus needs write", ctx do
    v = open(ctx.viewer_conn, ctx.base, %{"sessionId" => "vic-1", "documentId" => "p1"})
    wait_for(fn -> keys(ctx.topic) == ["api:vic-1"] end)

    assert focus(ctx.viewer_conn, ctx.base, %{"sessionId" => "vic-1", "field" => "x"}).status ==
             403

    close(v)
  end

  test "a session opened twice shows once in the room list", ctx do
    first = open(ctx.conn, ctx.base, %{"sessionId" => "dup-1", "name" => "Dee"})
    wait_for(fn -> match?(%{metas: [_]}, Presence.get_by_key(ctx.topic, "api:dup-1")) end)
    second = open(ctx.conn, ctx.base, %{"sessionId" => "dup-1", "name" => "Dee"})
    wait_for(fn -> match?(%{metas: [_, _]}, Presence.get_by_key(ctx.topic, "api:dup-1")) end)
    Process.sleep(100)

    last = second |> close() |> frames("presence") |> List.last()
    assert Enum.map(last["presences"], & &1["sessionId"]) == ["dup-1"]
    close(first)
  end

  test "a malformed sessionId is a 422", ctx do
    assert focus(ctx.conn, ctx.base, %{"sessionId" => "no spaces!"}).status == 422
    assert get(ctx.conn, ctx.base, %{"sessionId" => String.duplicate("x", 65)}).status == 422
  end

  test "a stream with no sessionId is given one", ctx do
    t = open(ctx.conn, ctx.base, %{})
    wait_for(fn -> length(keys(ctx.topic)) == 1 end)
    [%{"sessionId" => sid}] = frames(close(t), "session")
    assert sid =~ ~r/\A[0-9a-f]{12}\z/
  end
end
