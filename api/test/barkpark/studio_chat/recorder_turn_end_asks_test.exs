defmodule Barkpark.StudioChat.RecorderTurnEndAsksTest do
  @moduledoc """
  An ask still pending when its turn ends is canceled in the store
  (task-6b2fede385c12f8d, found by rev26735 on #26925).

  The named failure mode: the turn completes (or fails) while an ask is
  pending. The Recorder dropped its own tracking, but the stored row stayed
  "pending": Studio kept a live card for a turn that had ended, and a later
  run of the session could show two pending cards under one id.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Event

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

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    %{sid: sid, recorder: recorder}
  end

  test "an ask pending when its turn completes is canceled in the store",
       %{sid: sid, recorder: recorder} do
    frame(recorder, {:claude_chat_permission, ask("req-1")})
    assert ask_meta(sid, "req-1")["approval_status"] == "pending"

    frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

    meta = ask_meta(sid, "req-1")
    assert meta["approval_status"] == "canceled", "no card may stay live for a turn that ended"
    assert meta["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
    assert_received {:chat_permission_resolved, "req-1", :canceled}
  end

  test "a runtime ask pending when its turn completes is canceled in the store",
       %{sid: sid, recorder: recorder} do
    project(recorder, sid, :turn_started)
    project(recorder, sid, :approval_requested, approval_id: "ap-1", native: native_ask())
    assert ask_meta(sid, "ap-1")["approval_status"] == "pending"

    project(recorder, sid, :turn_completed, terminal_state: :completed)

    assert ask_meta(sid, "ap-1")["approval_status"] == "canceled"
    assert ask_meta(sid, "ap-1")["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
    assert_received {:chat_permission_resolved, "ap-1", :canceled}
  end

  test "a runtime ask pending when its turn fails is canceled in the store",
       %{sid: sid, recorder: recorder} do
    project(recorder, sid, :turn_started)
    project(recorder, sid, :approval_requested, approval_id: "ap-2", native: native_ask())

    project(recorder, sid, :error, error: %{"message" => "claude exited before turn completion"})

    assert ask_meta(sid, "ap-2")["approval_status"] == "canceled"
    assert StudioChat.get_session(sid).pending_approvals == 0
    # The cancel does not change how a mid-ask death reads (D39).
    assert StudioChat.get_session(sid).agent_state == "unknown"
  end

  # The cancel is pending-only: an answer that landed first stands.
  test "an ask answered before its turn completes keeps its answer",
       %{sid: sid, recorder: recorder} do
    frame(recorder, {:claude_chat_permission, ask("req-2")})
    assert {:ok, _} = StudioChat.update_approval_status(sid, "req-2", "allowed")

    frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

    assert ask_meta(sid, "req-2")["approval_status"] == "allowed"
    assert StudioChat.get_session(sid).pending_approvals == 0
    refute_received {:chat_permission_resolved, "req-2", :canceled}
  end

  # The turn going on keeps its ask: only the turn's END cancels it.
  test "an ask stays pending while its turn goes on", %{sid: sid, recorder: recorder} do
    frame(recorder, {:claude_chat_permission, ask("req-3")})
    frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "status"}})

    assert ask_meta(sid, "req-3")["approval_status"] == "pending"
    assert StudioChat.get_session(sid).pending_approvals == 1
  end

  defp ask(request_id),
    do: %{request_id: request_id, tool_name: "Bash", input: %{}, title: nil, decision_reason: nil}

  defp native_ask,
    do: %{"tool_name" => "Bash", "input" => %{"command" => "ls"}, "title" => "Run ls"}

  # Deliver a frame the way the Session does, then sync on the mailbox.
  defp frame(recorder, msg) do
    send(recorder, msg)
    _ = :sys.get_state(recorder)
  end

  defp project(recorder, sid, kind, fields \\ []) do
    event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, fields)
    assert :ok = GenServer.call(recorder, {:project_runtime_event, event, nil})
  end

  defp ask_meta(sid, request_id) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.find(&((&1.metadata || %{})["request_id"] == request_id))
    |> Map.fetch!(:metadata)
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
