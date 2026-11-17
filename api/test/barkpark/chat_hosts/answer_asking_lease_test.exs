defmodule Barkpark.ChatHosts.AnswerAskingLeaseTest do
  @moduledoc """
  An approval answer leased to a registered host names the run that asked it
  (task-754fd6f9a890e75e, rev26731 on #26895, point 1).

  The named failure mode: run A asks; the person answers and the ask is
  claimed; before the answer is leased, a newer turn (run B) displaces A. The
  answer was leased with only the session and approval ids, and the host
  routes by session to its one active run, so it reached B. Now the answer
  carries `payload.asked_lease_id` = A's lease, and the Go host delivers it
  only to A's run (internal/chathost/answer_lease_test.go).
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.AskingLease
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{ApprovalAnswer, Recorder, Runtime}
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

    host_session()
  end

  test "an answer to an ask a newer turn displaced after the claim names the asking run",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-1"))

    # Claimed, then run B takes the session before the answer is leased.
    deliver = fn ->
      b = lease!(ctx, "b")
      accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})
      send(self(), {:run_b, b.lease_id})
      Runtime.answer_approval("claude", remote_ref(ctx), "ap-1", :allow)
    end

    ApprovalAnswer.settle(sid, "ap-1", "allowed", deliver)
    assert_received {:run_b, b_lease}

    answer = answer_command!(ctx)

    assert asked_lease(answer) == a.lease_id,
           "the answer must name run A's lease, or the host gives it to run B (#{b_lease})"
  end

  test "an answer to the active run's own ask names that run", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-2"))

    assert :delivered =
             ApprovalAnswer.settle(sid, "ap-2", "allowed", fn ->
               Runtime.answer_approval("claude", remote_ref(ctx), "ap-2", :allow)
             end)

    assert asked_lease(answer_command!(ctx)) == a.lease_id
  end

  test "an ask no run of this session raised names no lease, and the answer is leased as before",
       %{host: host, sid: sid} do
    command = %Command{
      operation: :answer_approval,
      provider: "claude",
      session_id: sid,
      approval_id: "never-asked",
      payload: %{decision: "allow"}
    }

    assert AskingLease.stamp(host, command) == command
    assert AskingLease.find(host, "not-a-uuid", "never-asked") == nil
  end

  test "another workspace's lease is never named", %{host: host, sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started"})
    accept!(ctx, a, 2, ask("ap-3"))

    assert AskingLease.find(host, sid, "ap-3") == a.lease_id
    assert AskingLease.find(%{host | workspace_id: Ecto.UUID.generate()}, sid, "ap-3") == nil
  end

  # The registered-host runtime the Recorder holds for a host session, with
  # the real host directory and RemoteDispatch.
  defp remote_ref(%{host: host, sid: sid}) do
    {:ok, %Runtime.RemoteRef{} = ref} =
      Runtime.open("claude", %{
        execution_target: "registered_host",
        session_id: sid,
        workspace_id: host.workspace_id,
        execution_host_id: host.id
      })

    ref
  end

  defp answer_command!(%{host: host}) do
    answers =
      for %{command: %{operation: :answer_approval} = command} <- ChatHosts.next_commands(host),
          do: command

    assert length(answers) == 1, "want one answer leased, got #{inspect(answers)}"
    hd(answers)
  end

  defp asked_lease(%{payload: payload}), do: payload[:asked_lease_id]

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
      idempotency_key: "asking-#{tag}-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello #{tag}"}
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
    {:ok, ws} = Tenancy.create_workspace(%{slug: "asking-#{suffix}", name: "Asking #{suffix}"})

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

  # What the Go host enrolls with, so `Runtime.open/2` takes it as ready.
  defp capabilities, do: @fixture |> File.read!() |> Jason.decode!()

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
