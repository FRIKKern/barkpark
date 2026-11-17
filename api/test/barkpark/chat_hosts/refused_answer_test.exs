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

    answer = lease!(ctx, "answer", :answer_approval)
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

    answer = lease!(ctx, "answer", :answer_approval)
    accept!(ctx, answer, 1, refused("ap-2", a.lease_id))

    assert ask_meta(sid)["approval_status"] == "canceled"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  test "a delivered answer's plain ack leaves the ask answered", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-3"))
    assert :delivered = ApprovalAnswer.settle(sid, "ap-3", "allowed", fn -> :ok end)

    answer = lease!(ctx, "answer", :answer_approval)

    accept!(ctx, answer, 1, %{"kind" => "control_completed", "operation" => "answer_approval"})

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

    answer = lease!(ctx, "answer", :answer_approval)
    accept!(ctx, answer, 1, refused("ap-4", a.lease_id))

    assert ask_meta(sid)["cancel_reason"] == "superseded_by_newer_turn"
    refute_received {:chat_permission_resolved, "ap-4", :canceled}
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

  defp lease!(%{host: host, sid: sid, provider: provider}, tag, operation \\ :start) do
    payload =
      if operation == :start,
        do: %{cwd: System.tmp_dir!(), content: "hello #{tag}"},
        else: %{decision: "allow"}

    command = %Command{
      operation: operation,
      provider: provider,
      session_id: sid,
      idempotency_key: "refused-#{tag}-#{System.unique_integer([:positive])}",
      payload: payload
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
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
