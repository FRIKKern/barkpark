defmodule BarkparkWeb.ChatHostStatusControllerTest do
  @moduledoc """
  POST /v1/chat-host/leases/:lease_id/status (task-768e7dc4449cc7b9): a turn's
  status label, OUT of the cursor sequence.

  The named failure mode: the label rode `/v1/chat-host/events` at the turn's
  next cursor, so a text the provider wrote while the label's POST was in
  flight waited for it, and a 5xx/429 on the label was retried for up to two
  minutes with the turn's next event behind it. Off the sequence, the label
  takes no cursor and writes no ExecutionEvent row, so nothing can queue behind
  it.

  It is fenced like an event (Host credential, the host's live lease and its
  epoch, the per-host rate bucket), checked by the same label rules, streamed
  as the same runtime `:status` event BarkBot reads, and only while the turn is
  open and has no text. The positive control is first: on the old code the
  route does not exist and it fails.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors, registries and /v1/chat routes
  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatController

  @label "Explaining ocean tides"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if(Process.whereis(Barkpark.StudioChat.RuntimeSupervisor),
        do: DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
        else: []
      )
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    turn = host_turn()
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(turn.sid))
    turn
  end

  test "a label before the turn's first text reaches the session stream, takes no cursor and stores nothing",
       %{sid: sid, fence: fence} = turn do
    assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})
    assert_receive {:studio_chat_runtime_event, %Event{kind: :turn_started}}, 2_000
    status_before = StudioChat.get_session(sid).status
    rows_before = StudioChat.list_messages(sid, :global)

    conn = post_status(turn, %{"epoch" => fence.epoch, "label" => @label})
    assert json_response(conn, 202) == %{"streamed" => true}

    assert_receive {:studio_chat_runtime_event, %Event{kind: :status} = event}, 2_000
    assert event.native == %{"kind" => "status", "label" => @label}
    assert event.sequence == nil

    # The frame the session's SSE stream writes: the shape BarkBot reads.
    "event: runtime\ndata: " <> data = ChatController.sse_runtime_frame(event)
    frame = Jason.decode!(data)
    assert frame["kind"] == "status"
    assert frame["native"] == %{"kind" => "status", "label" => @label}

    # No row, no cursor, no session change.
    assert event_rows(fence.lease_id) == 1
    assert Repo.get!(ExecutionLease, fence.lease_id).last_cursor == 1
    assert StudioChat.get_session(sid).status == status_before
    assert StudioChat.list_messages(sid, :global) == rows_before

    # The turn's next event takes cursor 2: the label left no gap.
    assert {:ok, :accepted} = post_event(turn, 2, %{"kind" => "text_delta", "delta" => "Tides."})

    assert {:ok, :accepted} =
             post_event(turn, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert [reply] =
             sid |> StudioChat.list_messages(:global) |> Enum.filter(&(&1.role == "assistant"))

    assert reply.source_markdown == "Tides."
  end

  test "a label that reaches the server after the turn's first text is not streamed",
       %{fence: fence} = turn do
    assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})
    assert {:ok, :accepted} = post_event(turn, 2, %{"kind" => "text_delta", "delta" => "Tides."})
    assert_receive {:studio_chat_runtime_event, %Event{kind: :text_delta}}, 2_000

    conn = post_status(turn, %{"epoch" => fence.epoch, "label" => @label})
    assert json_response(conn, 202) == %{"streamed" => false}
    refute_receive {:studio_chat_runtime_event, %Event{kind: :status}}, 200
    assert event_rows(fence.lease_id) == 2
  end

  test "a label before the turn started, or after it ended, is not streamed",
       %{fence: fence} = turn do
    conn = post_status(turn, %{"epoch" => fence.epoch, "label" => @label})
    assert json_response(conn, 202) == %{"streamed" => false}

    assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})

    assert {:ok, :accepted} =
             post_event(turn, 2, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    # The lease is completed now, so the fence refuses it outright.
    conn = post_status(turn, %{"epoch" => fence.epoch, "label" => @label})
    assert json_response(conn, 409)["error"]["code"] == "stale_fence"
    refute_receive {:studio_chat_runtime_event, %Event{kind: :status}}, 200
  end

  test "the label is checked by the event path's rules: text only, whitespace folded, at most 60 codepoints",
       %{fence: fence} = turn do
    assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})

    for label <- [nil, 42, %{"text" => "hi"}, ["Explaining"], "", "   \n  "] do
      conn = post_status(turn, %{"epoch" => fence.epoch, "label" => label})
      assert json_response(conn, 422)["error"]["message"] == ":invalid_status_label"
    end

    conn = post_status(turn, %{"epoch" => fence.epoch})
    assert json_response(conn, 422)["error"]["message"] == ":invalid_status_label"
    refute_receive {:studio_chat_runtime_event, %Event{kind: :status}}, 100

    # 12 graphemes each carrying 166 combining marks: cut by codepoints.
    heavy = String.duplicate("a" <> String.duplicate("́", 166), 12)
    long = "  Mulling\n  " <> heavy

    conn = post_status(turn, %{"epoch" => fence.epoch, "label" => long})
    assert json_response(conn, 202) == %{"streamed" => true}
    assert_receive {:studio_chat_runtime_event, %Event{kind: :status, native: native}}, 2_000
    assert map_size(native) == 2
    assert length(String.codepoints(native["label"])) <= 60
    assert byte_size(native["label"]) <= 240
    # A grapheme that does not fit whole is dropped whole.
    assert native["label"] == "Mulling"
    refute native["label"] =~ ~r/\s\s|\n|^\s|\s$/
  end

  describe "the fence: only the host holding the live lease, at its epoch" do
    setup %{fence: fence} = turn do
      assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})
      %{lease_id: fence.lease_id, epoch: fence.epoch}
    end

    test "another host of the same workspace is refused", %{ws: ws, lease_id: lease_id} = turn do
      {_other, other_credential} = host!(ws, "other")
      conn = post_status(other_credential, lease_id, %{"epoch" => 1, "label" => @label})
      assert_stale(conn)
      assert_untouched(turn)
    end

    test "a wrong, missing or non-integer epoch is refused",
         %{epoch: epoch, lease_id: lease_id, credential: credential} = turn do
      for body <- [
            %{"epoch" => epoch + 1, "label" => @label},
            %{"epoch" => "#{epoch}", "label" => @label},
            %{"label" => @label}
          ] do
        assert_stale(post_status(credential, lease_id, body))
      end

      assert_untouched(turn)
    end

    test "a lease id that is not a UUID, or no lease, is refused without a crash",
         %{credential: credential} = turn do
      for lease_id <- ["not-a-uuid", Ecto.UUID.generate()] do
        assert_stale(post_status(credential, lease_id, %{"epoch" => 1, "label" => @label}))
      end

      assert_untouched(turn)
    end

    test "a host without a lease is refused before its label is read",
         %{ws: ws, lease_id: lease_id} do
      {_other, other_credential} = host!(ws, "other")
      assert_stale(post_status(other_credential, lease_id, %{"epoch" => 1, "label" => 42}))
    end

    test "an expired lease is refused and the label does not end the turn",
         %{sid: sid, lease_id: lease_id, epoch: epoch, credential: credential} = turn do
      past = DateTime.add(DateTime.utc_now(), -600, :second)

      {1, _} =
        Repo.update_all(from(l in ExecutionLease, where: l.id == ^lease_id),
          set: [expires_at: past]
        )

      status_before = StudioChat.get_session(sid).status
      assert_stale(post_status(credential, lease_id, %{"epoch" => epoch, "label" => @label}))
      assert StudioChat.get_session(sid).status == status_before
      assert Repo.get!(ExecutionLease, lease_id).status == "running"
      assert_untouched(turn)
    end

    test "a revoked lease is refused",
         %{lease_id: lease_id, epoch: epoch, credential: credential} = turn do
      {1, _} =
        Repo.update_all(from(l in ExecutionLease, where: l.id == ^lease_id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert_stale(post_status(credential, lease_id, %{"epoch" => epoch, "label" => @label}))
      assert_untouched(turn)
    end

    test "no credential, or a made-up one, is refused by the host pipeline",
         %{lease_id: lease_id, epoch: epoch} = turn do
      body = %{"epoch" => epoch, "label" => @label}

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat-host/leases/#{lease_id}/status", Jason.encode!(body))

      assert conn.status == 401
      assert post_status("made-up", lease_id, body).status == 401
      assert_untouched(turn)
    end
  end

  test "an old host's label on the event path is still taken at its cursor", turn do
    assert {:ok, :accepted} = post_event(turn, 1, %{"kind" => "turn_started"})
    assert {:ok, :accepted} = post_event(turn, 2, %{"kind" => "status", "label" => @label})
    assert_receive {:studio_chat_runtime_event, %Event{kind: :status, sequence: 2}}, 2_000
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp assert_stale(conn) do
    assert %{"code" => "stale_fence"} = json_response(conn, 409)["error"]
  end

  # A refused label streamed nothing and wrote nothing.
  defp assert_untouched(%{fence: fence}) do
    refute_receive {:studio_chat_runtime_event, %Event{kind: :status}}, 100
    assert event_rows(fence.lease_id) == 1
  end

  defp event_rows(lease_id),
    do: Repo.aggregate(from(e in ExecutionEvent, where: e.lease_id == ^lease_id), :count)

  defp post_status(%{credential: credential, fence: fence}, body),
    do: post_status(credential, fence.lease_id, body)

  defp post_status(credential, lease_id, body) do
    build_conn()
    |> put_req_header("authorization", "Host #{credential}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat-host/leases/#{lease_id}/status", Jason.encode!(body))
  end

  defp post_event(%{host: host, fence: fence}, cursor, event) do
    ChatHosts.accept_event(host, %{
      lease_id: fence.lease_id,
      epoch: fence.epoch,
      cursor: cursor,
      idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
      event: event
    })
  end

  defp host!(ws, name) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        approved_roots: [System.tmp_dir!()],
        capabilities: capabilities()
      })

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: capabilities()})
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    {host, enrolled.credential}
  end

  # One registered-host Claude session with a live Recorder and a leased send_turn.
  defp host_turn do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-label-#{suffix}", name: "Label"})
    {host, credential} = host!(ws, "laptop")
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
      idempotency_key: "label-#{suffix}",
      payload: %{cwd: System.tmp_dir!(), content: "how do ocean tides work?"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    %{ws: ws, host: host, credential: credential, sid: sid, fence: fence}
  end

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
    }
  end
end
