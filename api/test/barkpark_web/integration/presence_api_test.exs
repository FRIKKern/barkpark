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

  defp leave(conn, base, params), do: delete(conn, base <> "/leave", params)

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

    # The answer is the entry read back from the room, not the request echoed.
    assert Jason.decode!(resp.resp_body)["result"] == %{
             "sessionId" => "ann-1",
             "name" => "Ann",
             "documentId" => "p1",
             "field" => "seo.metaTitle",
             "client" => "api",
             "color" => PresenceState.pick_color("ann-1")
           }

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

  # task-936472b77285df5b — an explicit leave untracks the caller's own
  # session at once, instead of waiting on the keepalive to notice a dead
  # stream. Same auth/ownership shape as `focus`.
  describe "leave" do
    test "removes the entry and the room's other subscribers get the diff", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-1", "name" => "Ann"})
      b = open(ctx.conn, ctx.base, %{"sessionId" => "bob-leave-1", "name" => "Bob"})
      wait_for(fn -> keys(ctx.topic) == ["api:ann-leave-1", "api:bob-leave-1"] end)

      Phoenix.PubSub.subscribe(Barkpark.PubSub, ctx.topic)

      resp = leave(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-1"})
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body) == %{"left" => true, "sessionId" => "ann-leave-1"}

      wait_for(fn -> keys(ctx.topic) == ["api:bob-leave-1"] end)

      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
                     when is_map_key(leaves, "api:ann-leave-1"),
                     1_000

      # the stream itself ends on its own — leave does not wait for
      # :sse_overloaded to notice the session is gone.
      assert Task.await(a, 1_000).status == 200
      close(b)
    end

    test "another session can't remove yours", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-2"})
      wait_for(fn -> keys(ctx.topic) == ["api:ann-leave-2"] end)

      assert leave(ctx.other_conn, ctx.base, %{"sessionId" => "ann-leave-2"}).status == 404
      assert keys(ctx.topic) == ["api:ann-leave-2"]

      assert leave(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-2"}).status == 200
      wait_for(fn -> keys(ctx.topic) == [] end)
      assert Task.await(a, 1_000).status == 200
    end

    test "a second leave on an already-left session is a no-op", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-3"})
      wait_for(fn -> keys(ctx.topic) == ["api:ann-leave-3"] end)

      assert leave(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-3"}).status == 200
      wait_for(fn -> keys(ctx.topic) == [] end)
      assert Task.await(a, 1_000).status == 200

      # idempotent: no live session to remove is answered the same way as
      # "never existed" — the no-existence-oracle shape `focus` already uses,
      # not a crash and not a distinguishable error.
      assert leave(ctx.conn, ctx.base, %{"sessionId" => "ann-leave-3"}).status == 404
    end
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

  # task-d47c05259837093f — shared carets. `selection` rides the focus POST
  # and is relayed in the room entry and the stream frame.
  describe "focus selection" do
    @sel %{
      "anchor" => %{"blockId" => "b1", "offset" => 3},
      "head" => %{"blockId" => "b2", "path" => "rows[1].cells[0]", "offset" => 0}
    }

    test "a selection is accepted, read back in the entry, and relayed in the frame", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "sel-a", "name" => "Ann"})
      b = open(ctx.conn, ctx.base, %{"sessionId" => "sel-b", "name" => "Bob"})
      wait_for(fn -> keys(ctx.topic) == ["api:sel-a", "api:sel-b"] end)

      resp =
        focus(ctx.conn, ctx.base, %{
          "sessionId" => "sel-a",
          "documentId" => "p1",
          "field" => "body",
          "selection" => @sel
        })

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["result"]["selection"] == @sel

      wait_for(fn ->
        match?(%{metas: [%{selection: @sel}]}, Presence.get_by_key(ctx.topic, "api:sel-a"))
      end)

      Process.sleep(100)
      bob_body = close(b)

      assert Enum.any?(frames(bob_body, "presence"), fn %{"presences" => list} ->
               Enum.any?(list, &(&1["sessionId"] == "sel-a" and &1["selection"] == @sel))
             end)

      # A focus without a selection clears it, and the entry carries no key.
      resp = focus(ctx.conn, ctx.base, %{"sessionId" => "sel-a", "documentId" => "p1"})
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body)["result"], "selection")

      # An explicit null is the blurred state: accepted, no key.
      resp = focus(ctx.conn, ctx.base, %{"sessionId" => "sel-a", "selection" => nil})
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body)["result"], "selection")
      close(a)
    end

    test "a selection over 512 bytes of JSON is a 413, and nothing is applied", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "sel-big"})
      wait_for(fn -> keys(ctx.topic) == ["api:sel-big"] end)

      big = put_in(@sel, ["anchor", "blockId"], String.duplicate("x", 500))
      assert byte_size(Jason.encode!(big)) > 512

      resp = focus(ctx.conn, ctx.base, %{"sessionId" => "sel-big", "selection" => big})
      assert resp.status == 413
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "payload_too_large"

      # The boundary is inclusive: exactly 512 bytes is accepted.
      pad = 512 - byte_size(Jason.encode!(put_in(@sel, ["anchor", "blockId"], "")))
      at_cap = put_in(@sel, ["anchor", "blockId"], String.duplicate("y", pad))
      assert byte_size(Jason.encode!(at_cap)) == 512

      assert focus(ctx.conn, ctx.base, %{"sessionId" => "sel-big", "selection" => at_cap}).status ==
               200

      refute Enum.any?(
               Presence.get_by_key(ctx.topic, "api:sel-big").metas,
               &(&1[:selection] == big)
             )

      close(a)
    end

    test "a malformed selection is a 422", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "sel-bad"})
      wait_for(fn -> keys(ctx.topic) == ["api:sel-bad"] end)

      point = %{"blockId" => "b1", "offset" => 0}

      bad = [
        "b1:3",
        [point, point],
        %{"anchor" => point},
        %{"anchor" => point, "head" => point, "extra" => 1},
        %{"anchor" => %{"offset" => 0}, "head" => point},
        %{"anchor" => %{"blockId" => "", "offset" => 0}, "head" => point},
        %{"anchor" => %{"blockId" => 7, "offset" => 0}, "head" => point},
        %{"anchor" => %{"blockId" => "b1", "offset" => -1}, "head" => point},
        %{"anchor" => %{"blockId" => "b1", "offset" => 1.5}, "head" => point},
        %{"anchor" => %{"blockId" => "b1"}, "head" => point},
        %{"anchor" => %{"blockId" => "b1", "offset" => 0, "path" => 3}, "head" => point},
        %{"anchor" => %{"blockId" => "b1", "offset" => 0, "path" => ""}, "head" => point},
        %{"anchor" => %{"blockId" => "b1", "offset" => 0, "name" => "x"}, "head" => point}
      ]

      for sel <- bad do
        resp = focus(ctx.conn, ctx.base, %{"sessionId" => "sel-bad", "selection" => sel})
        assert resp.status == 422, "expected 422 for #{inspect(sel)}, got #{resp.status}"
        assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
      end

      assert %{metas: [meta]} = Presence.get_by_key(ctx.topic, "api:sel-bad")
      assert meta[:selection] == nil
      close(a)
    end

    test "another token cannot set a selection on a session it does not own", ctx do
      a = open(ctx.conn, ctx.base, %{"sessionId" => "sel-own"})
      wait_for(fn -> keys(ctx.topic) == ["api:sel-own"] end)

      assert focus(ctx.other_conn, ctx.base, %{"sessionId" => "sel-own", "selection" => @sel}).status ==
               404

      assert %{metas: [meta]} = Presence.get_by_key(ctx.topic, "api:sel-own")
      assert meta[:selection] == nil
      close(a)
    end

    test "the focus POST stays in the presence_focus rate class, and has no flat twin" do
      info =
        Phoenix.Router.route_info(
          BarkparkWeb.Router,
          "POST",
          "/w/ws/p/proj/v1/data/presence/production/focus",
          "localhost"
        )

      assert info.plug == BarkparkWeb.PresenceController
      assert info.plug_opts == :focus
      assert :scoped_api_presence_focus in info.pipe_through

      # Presence is scoped-only (the room is workspace + project): there is no
      # flat route a selection could ride outside a workspace.
      assert Phoenix.Router.route_info(
               BarkparkWeb.Router,
               "POST",
               "/v1/data/presence/production/focus",
               "localhost"
             ) == :error
    end
  end
end
