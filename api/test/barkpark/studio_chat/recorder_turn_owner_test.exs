defmodule Barkpark.StudioChat.RecorderTurnOwnerTest do
  @moduledoc """
  Only the turn's own lease ends it (task-5d1f639852927c4e).

  The named failure mode: `ChatHosts` decides whether an older lease's event is
  superseded by reading whether a newer lease took a `turn_started`, before
  that `turn_started` commits. The older close can therefore reach the
  Recorder just after the newer turn began (a few ms; two turns at once), and
  the Recorder, which could not tell leases apart, ended the newer turn: the
  session left `working` and the newer reply's first text had no turn.

  Each projected host event names its lease (`Recorder.TurnOwner`): a terminal
  event from a lease that is not the turn's owner is not taken. What stays: the
  owner's own close ends the turn, and a projection with no lease (a managed
  runtime) ends it as it always did.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Event

  @older "11111111-1111-4111-8111-111111111111"
  @newer "22222222-2222-4222-8222-222222222222"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
          DynamicSupervisor.terminate_child(pid, child)
        end
      end

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
    %{sid: sid, recorder: recorder}
  end

  test "an older lease's close projected after the newer turn_started does not end the newer turn",
       %{sid: sid, recorder: recorder} do
    project(recorder, sid, @older, :turn_started)
    project(recorder, sid, @newer, :turn_started)
    project(recorder, sid, @older, :turn_completed, terminal_state: :completed)

    assert StudioChat.get_session(sid).status == "working"

    project(recorder, sid, @newer, :text_delta, native: %{"params" => %{"delta" => "Newer."}})
    project(recorder, sid, @newer, :turn_completed, terminal_state: :completed)

    assert replies(sid) == ["Newer."]
    assert StudioChat.get_session(sid).status == "active"
  end

  test "an older lease's final error projected after the newer turn_started does not end it",
       %{sid: sid, recorder: recorder} do
    project(recorder, sid, @older, :turn_started)
    project(recorder, sid, @newer, :turn_started)
    project(recorder, sid, @older, :error, terminal_state: :failed, error: %{"message" => "gone"})

    assert StudioChat.get_session(sid).status == "working"
  end

  test "the turn's own lease still ends it", %{sid: sid, recorder: recorder} do
    project(recorder, sid, @older, :turn_started)
    project(recorder, sid, @older, :text_delta, native: %{"params" => %{"delta" => "Mine."}})
    project(recorder, sid, @older, :turn_completed, terminal_state: :completed)

    assert replies(sid) == ["Mine."]
    assert StudioChat.get_session(sid).status == "active"
  end

  test "a close projected with no lease ends the turn as it always did",
       %{sid: sid, recorder: recorder} do
    project(recorder, sid, @older, :turn_started)
    project(recorder, sid, @older, :text_delta, native: %{"params" => %{"delta" => "Kept."}})
    project(recorder, sid, nil, :turn_completed, terminal_state: :completed)

    assert replies(sid) == ["Kept."]
    assert StudioChat.get_session(sid).status == "active"
  end

  defp project(recorder, sid, lease_id, kind, fields \\ []) do
    event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, fields)
    assert :ok = GenServer.call(recorder, {:project_runtime_event, event, lease_id})
  end

  defp replies(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.source_markdown)
  end
end
