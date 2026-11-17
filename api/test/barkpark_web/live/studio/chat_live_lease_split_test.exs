defmodule BarkparkWeb.Studio.ChatLiveLeaseSplitTest do
  @moduledoc """
  The live bubble splits where the stored rows split (task-f0d668d89e21f5f8).

  The named failure mode: when another lease's event arrives while a turn is
  open, `Recorder.TurnOwner` stores the open text as its own row
  (task-b0cbddc9d0f2e2aa). ChatLive kept one `streaming` buffer across both
  leases and appended it whole on `turn_completed`, so a viewer saw
  "Older-1.Newer." as one live reply, and two rows only after a reload.

  On a split the Recorder now broadcasts `{:chat_turn_split, session_id}`, and
  ChatLive commits its open bubble. It is not a `turn_completed`: the SSE
  stream ignores the tuple, so `bp chat` and the TUI do not read a split as
  the turn ending. A projection with no lease (a managed runtime) never splits.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Event

  @admin_token "chat-lease-split-admin-token"
  @older "11111111-1111-4111-8111-111111111111"
  @newer "22222222-2222-4222-8222-222222222222"

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "chat lease split admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

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

    conn = init_test_session(conn, %{"api_token" => @admin_token})
    {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    %{sid: sid, recorder: recorder, view: view}
  end

  test "T1: older text, then the newer lease's turn, are two live replies", ctx do
    project(ctx, @older, :turn_started)
    project(ctx, @older, :text_delta, "Older-1.")
    project(ctx, @newer, :turn_started)
    project(ctx, @newer, :text_delta, "Newer.")
    project(ctx, @newer, :turn_completed, nil, terminal_state: :completed)

    assert live_replies(ctx.view) == ["Older-1.", "Newer."]
    assert stored_replies(ctx.sid) == ["Older-1.", "Newer."]
  end

  test "T7: the newer lease's text, then older text in the open turn, are two live replies",
       ctx do
    project(ctx, @newer, :turn_started)
    project(ctx, @newer, :text_delta, "Newer-part.")
    project(ctx, @older, :text_delta, "Older reply.")
    project(ctx, @older, :turn_completed, nil, terminal_state: :completed)

    assert live_replies(ctx.view) == ["Newer-part.", "Older reply."]
    assert stored_replies(ctx.sid) == ["Newer-part.", "Older reply."]
  end

  test "a split sends no turn_completed to stream clients", ctx do
    project(ctx, @older, :turn_started)
    project(ctx, @older, :text_delta, "Older-1.")
    project(ctx, @newer, :turn_started)

    sid = ctx.sid
    assert_received {:chat_turn_split, ^sid}
    refute_received {:studio_chat_runtime_event, %Event{kind: :turn_completed}}
  end

  test "a managed runtime's turn (no lease) still renders as one live reply", ctx do
    project(ctx, nil, :turn_started)
    project(ctx, nil, :text_delta, "A.")
    project(ctx, nil, :turn_started)
    project(ctx, nil, :text_delta, "B.")
    project(ctx, nil, :turn_completed, nil, terminal_state: :completed)

    assert live_replies(ctx.view) == ["A.\n\nB."]
    refute_received {:chat_turn_split, _}
  end

  defp project(%{sid: sid, recorder: recorder}, lease_id, kind, delta \\ nil, fields \\ []) do
    fields = if delta, do: [{:native, %{"params" => %{"delta" => delta}}} | fields], else: fields
    event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, fields)
    assert :ok = GenServer.call(recorder, {:project_runtime_event, event, lease_id})
  end

  # `render/1` is a call to the LiveView, so every broadcast sent before it is
  # handled first.
  defp live_replies(view) do
    render(view)

    :sys.get_state(view.pid).socket.assigns.messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.map(& &1.text)
  end

  defp stored_replies(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.source_markdown)
  end
end
