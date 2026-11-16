defmodule BarkparkWeb.ChatHostEventNulTest do
  @moduledoc """
  A chat-host event whose text holds U+0000 (task-6497a4925af9b22f).

  The named failure mode: the event payload is stored as jsonb, and Postgres
  refuses U+0000 there (22P05). `POST /v1/chat-host/events` answered 500, the
  Go host retries a 5xx with the same cursor for two minutes, and the turn
  stalled until the lease expired. Model output, a tool result or echoed file
  bytes can carry that character.

  The server now stores U+FFFD (the replacement character) in its place, in
  every string the event carries, keys and nested values alike. The event is
  taken, so the host keeps publishing and no later event of the turn is lost;
  a 4xx would have been final for the host and ended the turn, dropping the
  rest of the reply (internal/chathost/runner.go).
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  @nul <<0>>
  @fffd "�"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    host_turn()
  end

  test "a text_delta holding U+0000 is taken, stored with U+FFFD, and the turn ends cleanly",
       %{sid: sid, fence: fence} = turn do
    assert post_event(turn, 1, %{"kind" => "turn_started"}).status == 202

    conn = post_event(turn, 2, %{"kind" => "text_delta", "delta" => "a" <> @nul <> "b"})
    assert json_response(conn, 202) == %{"accepted" => true}

    # The next event lands at the next cursor: nothing after it is lost.
    assert post_event(turn, 3, %{"kind" => "text_delta", "delta" => " then more"}).status == 202

    conn = post_event(turn, 4, %{"kind" => "turn_completed", "terminal_state" => "completed"})
    assert conn.status == 202

    lease = Repo.get!(ExecutionLease, fence.lease_id)
    assert lease.last_cursor == 4
    assert lease.status == "completed"

    assert payload_at(fence.lease_id, 2) == %{
             "kind" => "text_delta",
             "delta" => "a" <> @fffd <> "b"
           }

    assert [reply] = rows(sid, "assistant")
    assert reply.source_markdown == "a" <> @fffd <> "b then more"
    refute StudioChat.get_session(sid).status == "working"
  end

  test "U+0000 in any nested string, list item or key is stored as U+FFFD",
       %{fence: fence} = turn do
    assert post_event(turn, 1, %{"kind" => "turn_started"}).status == 202

    item = %{
      "type" => "tool_result",
      "id" => "item" <> @nul,
      "content" => [%{"type" => "text", "text" => "bytes:" <> @nul <> @nul}, 7, true, nil],
      "meta" => %{("path" <> @nul) => %{"deep" => ["x" <> @nul]}}
    }

    conn =
      post_event(turn, 2, %{"kind" => "item_completed", "item_id" => "i" <> @nul, "item" => item})

    assert json_response(conn, 202) == %{"accepted" => true}

    stored = payload_at(fence.lease_id, 2)
    refute Jason.encode!(stored) =~ "\\u0000"

    assert stored == %{
             "kind" => "item_completed",
             "item_id" => "i" <> @fffd,
             "item" => %{
               "type" => "tool_result",
               "id" => "item" <> @fffd,
               "content" => [
                 %{"type" => "text", "text" => "bytes:" <> @fffd <> @fffd},
                 7,
                 true,
                 nil
               ],
               "meta" => %{("path" <> @fffd) => %{"deep" => ["x" <> @fffd]}}
             }
           }

    for {kind, event} <- [
          {"error", %{"kind" => "error", "error" => %{"message" => "boom" <> @nul}}},
          {"approval_requested",
           %{
             "kind" => "approval_requested",
             "approval_id" => "ask-1",
             "tool_name" => "Write",
             "input" => %{"content" => "x" <> @nul},
             "title" => "Write" <> @nul
           }}
        ] do
      cursor = last_cursor(fence.lease_id) + 1
      conn = post_event(turn, cursor, event)
      assert conn.status == 202, "#{kind} answered #{conn.status}: #{conn.resp_body}"
      refute Jason.encode!(payload_at(fence.lease_id, cursor)) =~ "\\u0000"
    end
  end

  test "a retry of the same event at the same cursor is a duplicate, not a conflict",
       %{fence: fence} = turn do
    assert post_event(turn, 1, %{"kind" => "turn_started"}).status == 202
    event = %{"kind" => "text_delta", "delta" => "a" <> @nul}

    assert post_event(turn, 2, event).status == 202

    assert json_response(post_event(turn, 2, event), 200) == %{
             "accepted" => false,
             "duplicate" => true
           }

    assert last_cursor(fence.lease_id) == 2
  end

  test "text a real host sends today is stored exactly as sent", %{fence: fence} = turn do
    assert post_event(turn, 1, %{"kind" => "turn_started"}).status == 202

    for text <- [
          "plain words",
          "emoji 🐕‍🦺 and RTL שלום",
          "\n\t\r",
          <<1>>,
          <<0x7F>>,
          @fffd,
          "the literal \\u0000",
          ""
        ] do
      cursor = last_cursor(fence.lease_id) + 1
      event = %{"kind" => "text_delta", "delta" => text}
      assert post_event(turn, cursor, event).status == 202
      assert payload_at(fence.lease_id, cursor) == event
    end

    # A status label keeps its own rule: a control character folds to a space.
    cursor = last_cursor(fence.lease_id) + 1

    assert post_event(turn, cursor, %{"kind" => "status", "label" => "Mulling" <> @nul <> "it"}).status ==
             202

    assert payload_at(fence.lease_id, cursor) == %{"kind" => "status", "label" => "Mulling it"}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp post_event(%{credential: credential, fence: fence}, cursor, event) do
    build_conn()
    |> put_req_header("authorization", "Host #{credential}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat-host/events",
      Jason.encode!(%{
        lease_id: fence.lease_id,
        epoch: fence.epoch,
        cursor: cursor,
        idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
        event: event
      })
    )
  end

  defp payload_at(lease_id, cursor),
    do:
      Repo.one!(
        from(e in ExecutionEvent,
          where: e.lease_id == ^lease_id and e.cursor == ^cursor,
          select: e.payload
        )
      )

  defp last_cursor(lease_id), do: Repo.get!(ExecutionLease, lease_id).last_cursor

  defp rows(sid, role),
    do: sid |> StudioChat.list_messages(:global) |> Enum.filter(&(&1.role == role))

  # One registered-host Claude session with a live Recorder and a leased turn.
  defp host_turn do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-nul-#{suffix}", name: "Nul #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "laptop-#{suffix}",
        approved_roots: [System.tmp_dir!()],
        capabilities: capabilities()
      })

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: capabilities()})
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        ws.id
      )

    {:ok, _recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "nul-#{suffix}",
      payload: %{cwd: System.tmp_dir!(), content: "print a NUL byte"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    %{host: host, credential: enrolled.credential, sid: sid, fence: fence}
  end

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
    }
  end

  defp reap_recorders do
    if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
      for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
        DynamicSupervisor.terminate_child(pid, child)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
