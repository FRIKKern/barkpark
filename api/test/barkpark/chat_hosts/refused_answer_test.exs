defmodule Barkpark.ChatHosts.RefusedAnswerTest do
  @moduledoc """
  A host-refused approval answer is not left stored as answered
  (task-746c02d760f26ce7, rev26735 on #26925).

  The named failure mode: the answer to run A's ask flips the card to
  "allowed", then the host refuses it (its active run is not A's lease) with
  `control_completed` + `refused`. The server took that ack like a delivered
  one, so the card read "allowed" although the answer reached no run.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RemoteDispatch
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{ApprovalAnswer, Recorder}
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

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

    ctx = host_session()
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(ctx.sid))
    ctx
  end

  test "an answer the host refused leaves its ask canceled, not allowed", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-1"))
    assert :delivered = ApprovalAnswer.settle(sid, "ap-1", "allowed", fn -> :ok end)
    assert ask_meta(sid)["approval_status"] == "allowed"

    answer = answer!(ctx, "ap-1")
    accept!(ctx, answer, 1, refused("ap-1", a.lease_id))

    meta = ask_meta(sid)

    assert meta["approval_status"] == "canceled",
           "the answer reached no run, so the card is not allowed"

    assert meta["cancel_reason"] == "asking_run_gone"
    assert StudioChat.get_session(sid).pending_approvals == 0
    assert_received {:chat_permission_resolved, "ap-1", :canceled}
  end

  test "a refusal that lands while the ask is still pending cancels it", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-2"))

    answer = answer!(ctx, "ap-2")
    accept!(ctx, answer, 1, refused("ap-2", a.lease_id))

    assert ask_meta(sid)["approval_status"] == "canceled"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  test "a refusal stored while a newer turn is open still cancels the answered ask",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-5"))
    assert :delivered = ApprovalAnswer.settle(sid, "ap-5", "allowed", fn -> :ok end)

    # The answer was sent, then the user's next message started run b before
    # the host refused it: the refusal is superseded and never projected.
    answer = answer!(ctx, "ap-5")
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
    accept!(ctx, answer, 1, refused("ap-5", a.lease_id))

    assert ask_meta(sid)["approval_status"] == "canceled"
    assert_received {:chat_permission_resolved, "ap-5", :canceled}
  end

  test "a delivered answer's plain ack leaves the ask answered", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-3"))
    assert :delivered = ApprovalAnswer.settle(sid, "ap-3", "allowed", fn -> :ok end)

    answer = answer!(ctx, "ap-3")

    # The host's delivered ack carries no approval_id; one is added here so
    # only the missing `refused` reason keeps the ask answered.
    accept!(ctx, answer, 1, %{
      "kind" => "control_completed",
      "operation" => "answer_approval",
      "approval_id" => "ap-3"
    })

    assert ask_meta(sid)["approval_status"] == "allowed"
    refute_received {:chat_permission_resolved, "ap-3", :canceled}
  end

  test "an ask already canceled keeps its reason and is not broadcast again",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-4"))
    reason = %{"cancel_reason" => "superseded_by_newer_turn"}
    assert {:ok, _} = StudioChat.update_approval_status(sid, "ap-4", "canceled", reason)

    answer = answer!(ctx, "ap-4")
    accept!(ctx, answer, 1, refused("ap-4", a.lease_id))

    assert ask_meta(sid)["cancel_reason"] == "superseded_by_newer_turn"
    refute_received {:chat_permission_resolved, "ap-4", :canceled}
  end

  # rev26739 on #26949: Codex numbers asks per process, so run b asks under
  # run a's id. A late refusal of the answer to a's ask is about a's row only.
  test "a refusal of a's answer leaves b's same-id pending ask alone", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("0"))
    assert :delivered = ApprovalAnswer.settle(sid, "0", "allowed", fn -> :ok end)
    answer = answer!(ctx, "0")
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
    accept!(ctx, b, 2, ask("0"))
    assert StudioChat.get_session(sid).pending_approvals == 1

    accept!(ctx, answer, 1, refused("0", a.lease_id))

    [ra, rb] = asks(sid)
    assert rb.metadata["approval_status"] == "pending", "b's own ask is still waiting"
    assert StudioChat.get_session(sid).pending_approvals == 1
    assert ra.metadata["approval_status"] == "canceled", "the refusal was about a's ask"
  end

  test "a refusal of a's answer leaves b's same-id answered ask alone", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("0"))
    assert :delivered = ApprovalAnswer.settle(sid, "0", "allowed", fn -> :ok end)
    answer = answer!(ctx, "0")
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
    accept!(ctx, b, 2, ask("0"))
    assert :delivered = ApprovalAnswer.settle(sid, "0", "denied", fn -> :ok end)

    accept!(ctx, answer, 1, refused("0", a.lease_id))

    [ra, rb] = asks(sid)
    assert rb.metadata["approval_status"] == "denied", "b took its answer"
    assert ra.metadata["approval_status"] == "canceled"
  end

  # a's ask was taken while b's newer turn was open, so it made no card; b
  # then asked under the same id. A refusal naming a has no row of a's to
  # cancel, and b's row, stored after b asked, is not a's.
  test "a refusal for an ask that made no card leaves a later same-id ask alone",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
    accept!(ctx, a, 2, ask("0"))
    assert asks(sid) == []
    answer = answer!(ctx, "0")
    accept!(ctx, b, 2, ask("0"))

    accept!(ctx, answer, 1, refused("0", a.lease_id))

    assert [%{metadata: %{"approval_status" => "pending"}}] = asks(sid)
  end

  # The same, with an older run's same-id ask answered before a asked: that
  # row was stored before a's ask, so it is not a's either.
  test "a refusal for an ask that made no card leaves an earlier same-id answer alone",
       %{sid: sid} = ctx do
    c = lease!(ctx, "c")
    accept!(ctx, c, 1, %{"kind" => "turn_started", "turn_id" => "t-c"})
    accept!(ctx, c, 2, ask("0"))
    assert :delivered = ApprovalAnswer.settle(sid, "0", "allowed", fn -> :ok end)
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
    accept!(ctx, a, 2, ask("0"))
    answer = answer!(ctx, "0")

    accept!(ctx, answer, 1, refused("0", a.lease_id))

    assert [%{metadata: %{"approval_status" => "allowed"}}] = asks(sid)
  end

  # The refused lease must be the answer to this approval: a refusal naming
  # another id on it touches nothing.
  test "a refusal naming another approval than its lease answers is ignored",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-6"))
    accept!(ctx, a, 3, ask("ap-7"))
    assert :delivered = ApprovalAnswer.settle(sid, "ap-7", "allowed", fn -> :ok end)

    answer = answer!(ctx, "ap-6")
    accept!(ctx, answer, 1, refused("ap-7", a.lease_id))

    assert Enum.map(asks(sid), & &1.metadata["approval_status"]) == ["pending", "allowed"]
  end

  # The ack exactly as the Go host sends it (answer_lease.go).
  defp refused(approval_id, asked) do
    %{
      "kind" => "control_completed",
      "operation" => "answer_approval",
      "approval_id" => approval_id,
      "refused" =>
        "approval #{inspect(approval_id)} was asked by run #{asked}, which is no longer " <>
          "this session's active run, so the answer was not sent"
    }
  end

  defp ask_meta(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.find(&(&1.role == "approval"))
    |> Map.fetch!(:metadata)
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

  defp lease!(%{host: host, sid: sid, provider: provider}, tag) do
    command = %Command{
      operation: :start,
      provider: provider,
      session_id: sid,
      idempotency_key: "refused-#{tag}-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello #{tag}"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  # An answer leased the way `Runtime.answer_approval/4` leases one, so
  # `AskingLease` names the asking lease at dispatch.
  defp answer!(%{host: host, sid: sid, provider: provider}, approval_id) do
    command = %Command{
      operation: :answer_approval,
      provider: provider,
      session_id: sid,
      approval_id: approval_id,
      idempotency_key: Ecto.UUID.generate(),
      payload: %{decision: "allow"}
    }

    {:ok, fence} = RemoteDispatch.dispatch(host, command, [])
    fence
  end

  defp asks(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "approval"))
    |> Enum.sort_by(& &1.seq)
  end

  defp ask(approval_id) do
    %{
      "kind" => "approval_requested",
      "approval_id" => approval_id,
      "tool_name" => "Bash",
      "input" => %{"command" => "ls"},
      "title" => "Run ls"
    }
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "refused-#{suffix}", name: "Refused #{suffix}"})
    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "laptop-#{suffix}",
        approved_roots: [System.tmp_dir!()],
        capabilities: caps
      })

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: caps})
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
