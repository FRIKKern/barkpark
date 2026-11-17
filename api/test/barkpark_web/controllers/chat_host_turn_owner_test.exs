defmodule BarkparkWeb.ChatHostTurnOwnerTest do
  @moduledoc """
  Two live leases of one session never make one reply row
  (task-b0cbddc9d0f2e2aa).

  The named failure mode: the Recorder keeps one turn's text and could not
  tell leases apart. Since #26812 an older lease's events are kept out while
  a newer turn is open, but two shapes still joined two replies into one row:

    * T1/T3: the older lease's text was taken BEFORE the newer lease's
      `turn_started`, which the Recorder took as the same turn going on:
      "Older-1.\\n\\nNewer.";
    * T7: the newer lease's host went silent, the expiry sweep ended it while
      the older lease was live (so its close was not projected), and the
      older text was appended with no break: "Newer-part.Older reply.".

  Each projected host event now names its lease (`Recorder.TurnOwner`), and an
  event from another lease while the turn is open stores the open text as its
  own row first. What stays as it was: one lease's own repeated
  `turn_started` (an older claude host sends one per message) joins its
  messages as paragraphs of one row, and an event with no lease (a managed
  runtime) changes nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.Tenancy

  @dead_close %{
    "kind" => "terminal",
    "terminal_state" => "error",
    "error" => %{"message" => "claude exited before turn completion"}
  }

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

    host_session()
  end

  test "T1: older text taken before the newer turn_started is its own row", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older-1."})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, old, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})
    assert StudioChat.get_session(sid).status == "working", "the newer turn is not ended"
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Older-1.", "Newer."]
    refute StudioChat.get_session(sid).status == "working"
  end

  test "T3: a stopped turn's text, its close after the next turn_started, is its own row",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, old, 3, @dead_close)
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Half", "Next."]
  end

  test "T7: older text after the sweep ended the newer lease is its own row", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer-part."})

    past = DateTime.add(DateTime.utc_now(), -600)

    Repo.update_all(from(l in ExecutionLease, where: l.id == ^new.lease_id),
      set: [expires_at: past]
    )

    assert ChatHosts.end_expired_turns(DateTime.utc_now(), ~U[2000-01-01 00:00:00Z]) == 1
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older reply."})
    accept!(ctx, old, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Newer-part.", "Older reply."]
    refute StudioChat.get_session(sid).status == "working"
  end

  test "one lease's repeated turn_started still joins its messages into one row",
       %{sid: sid} = ctx do
    fence = lease!(ctx, "one")
    accept!(ctx, fence, 1, %{"kind" => "turn_started"})
    accept!(ctx, fence, 2, %{"kind" => "text_delta", "delta" => "First."})
    accept!(ctx, fence, 3, %{"kind" => "turn_started"})
    accept!(ctx, fence, 4, %{"kind" => "text_delta", "delta" => "Second."})
    accept!(ctx, fence, 5, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["First.\n\nSecond."]
  end

  # A Stop's lease is newer but starts no turn: its ack does not take the turn
  # over, so the stopped turn's late text stays in the same row.
  test "a Stop's ack mid-turn does not split the stopped turn's reply", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
    accept!(ctx, old, 3, %{"kind" => "text_delta", "delta" => " and late"})
    accept!(ctx, old, 4, %{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    assert replies(sid) == ["Half and late"]
    refute StudioChat.get_session(sid).status == "working"
  end

  # A managed runtime's events carry no lease: the projection without one is
  # the Recorder path it always was, including a second turn_started.
  test "events projected without a lease keep the turn they were in", %{sid: sid} do
    recorder = Recorder.whereis(sid)

    for {kind, extra} <- [
          {:turn_started, %{}},
          {:text_delta, %{native: %{"params" => %{"delta" => "A."}}}},
          {:turn_started, %{}},
          {:text_delta, %{native: %{"params" => %{"delta" => "B."}}}},
          {:turn_completed, %{terminal_state: :completed}}
        ] do
      event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, extra)
      assert :ok = GenServer.call(recorder, {:project_runtime_event, event, nil})
    end

    assert replies(sid) == ["A.\n\nB."]
  end

  defp accept!(%{host: host}, fence, cursor, event) do
    assert {:ok, :accepted} =
             ChatHosts.accept_event(host, %{
               lease_id: fence.lease_id,
               epoch: fence.epoch,
               cursor: cursor,
               idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
               event: event
             })
  end

  defp lease!(%{host: host, sid: sid, provider: provider}, tag, operation \\ :start) do
    payload =
      if operation == :start,
        do: %{cwd: System.tmp_dir!(), content: "hello #{tag}"},
        else: %{}

    command = %Command{
      operation: operation,
      provider: provider,
      session_id: sid,
      idempotency_key: "owner-#{tag}-#{System.unique_integer([:positive])}",
      payload: payload
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  defp replies(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.source_markdown)
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-owner-#{suffix}", name: "Owner #{suffix}"})

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
    %{host: host, sid: sid, provider: "claude"}
  end

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{"installed" => true, "auth_ready" => true},
        "codex" => %{"installed" => true, "auth_ready" => true}
      }
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
