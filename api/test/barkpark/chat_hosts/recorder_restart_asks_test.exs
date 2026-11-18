defmodule Barkpark.ChatHosts.RecorderRestartAsksTest do
  @moduledoc """
  A Recorder that restarts still cancels the asking run's pending asks when
  that run's turn ends (task-442a665f443e38a8, rev26735 on #26941).

  The named failure mode: run A asks, the session's Recorder restarts, then A
  closes its own turn. The fresh Recorder tracked no pending asks and no turn
  owner, so the close canceled nothing, and A's ask stayed "pending" in the
  store: a live card for a turn that had ended.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.Tenancy

  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

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

  test "after a Recorder restart, the asking run's own close cancels its pending ask",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-1"))
    restart_recorder(ctx)

    accept!(ctx, a, 3, @dead_close)

    meta = ask_meta(sid)
    assert meta["approval_status"] == "canceled", "no card may stay live for a turn that ended"
    assert meta["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  # The close lands while no Recorder runs, so the next one replays it: the
  # asks must be restored before the replay.
  test "a close taken while the Recorder was down cancels the ask on replay",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-2"))
    stop_recorder(sid)

    accept!(ctx, a, 3, @dead_close)
    start_recorder(ctx)

    assert ask_meta(sid)["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  # The owner is restored too: a refused newer send_turn's close never owned
  # the turn, and A's run is alive, so its ask stays answerable (#26941).
  test "after a restart, a refused newer send_turn's close leaves the live run's ask pending",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-3"))
    restart_recorder(ctx)

    b = lease!(ctx, "b")

    accept!(ctx, b, 1, %{
      "kind" => "terminal",
      "terminal_state" => "error",
      "error" => %{"message" => "session already has an active turn"}
    })

    assert ask_meta(sid)["approval_status"] == "pending"
    assert StudioChat.get_session(sid).pending_approvals == 1
  end

  # The asking turn counts as open, so a newer lease's turn displaces it.
  test "after a restart, a newer run's turn cancels the asking run's ask as displaced",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-4"))
    restart_recorder(ctx)

    b = lease!(ctx, "b")
    accept!(ctx, b, 1, %{"kind" => "turn_started", "turn_id" => "t-b"})

    assert ask_meta(sid)["cancel_reason"] == "superseded_by_newer_turn"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  # task-e1502531570f43a8: the Recorder's `:via` name is registered before its
  # init/1 runs, so ChatHosts can project a live close to it during init, and
  # that call is handled before the replay message init sends itself. The
  # callbacks are driven here in that mailbox order.
  test "a close projected before the restart replay is handled still cancels the restored ask",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-5"))
    stop_recorder(sid)

    {:ok, state} = Recorder.init(recorder_opts(ctx))
    on_exit(fn -> Barkpark.StudioChat.RuntimeAdmission.release(state.admission) end)

    close = %Event{provider: "claude", session_id: sid, kind: :turn_completed}
    from = {self(), make_ref()}

    {:reply, :ok, state} =
      Recorder.handle_call({:project_runtime_event, close, a.lease_id}, from, state)

    {:noreply, state} = Recorder.handle_info(:replay_registered_host_events, state)

    meta = ask_meta(sid)
    assert meta["approval_status"] == "canceled", "the asking run's close came; its card is done"
    assert meta["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
    refute state.runtime_turn_open?, "the ended turn must not be restored as open"
  end

  defp restart_recorder(%{sid: sid} = ctx) do
    stop_recorder(sid)
    start_recorder(ctx)
  end

  defp stop_recorder(sid) do
    pid = Recorder.whereis(sid)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # The Recorder a registered-host send starts (ChatController), so its
  # runtime is the host's, not a local process. A synchronous call after
  # `ensure` waits out the init-time replay.
  defp start_recorder(ctx) do
    {:ok, pid} = Recorder.ensure(recorder_opts(ctx))
    :sys.get_state(pid)
  end

  defp recorder_opts(%{sid: sid, host: host, ws: ws}) do
    %{
      session_id: sid,
      provider: "claude",
      execution_target: "registered_host",
      execution_host_id: host.id,
      workspace_id: ws.id,
      cwd: System.tmp_dir!(),
      mode: "plan",
      resume: false
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
      idempotency_key: "restart-#{tag}-#{System.unique_integer([:positive])}",
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
    {:ok, ws} = Tenancy.create_workspace(%{slug: "restart-#{suffix}", name: "Restart #{suffix}"})
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

    ctx = %{host: host, sid: sid, ws: ws, provider: "claude"}
    start_recorder(ctx)
    ctx
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
