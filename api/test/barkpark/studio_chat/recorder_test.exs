defmodule Barkpark.StudioChat.RecorderTest do
  @moduledoc """
  The server-owned chat runtime (wave 4, charter D28). The Recorder is the
  Session's PERMANENT sink: these tests prove the store writes happen in the
  RUNTIME — with no LiveView anywhere — and that every frame rebroadcasts to
  PubSub subscribers. This is the "close the tab, the turn still lands"
  guarantee, tested at its owning seam.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    # `cat` echoes stdin; we drive frames by sending them to the Recorder
    # directly (the Session's sink delivery shape), so no real CLI is needed.
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
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

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
    %{sid: id, recorder: recorder}
  end

  # Deliver a frame the way the Session does, then sync on the mailbox.
  defp frame(recorder, msg) do
    send(recorder, msg)
    :sys.get_state(recorder)
    :ok
  end

  test "ensure/1 is idempotent — one recorder per session", %{sid: sid, recorder: recorder} do
    assert {:ok, ^recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
    assert Recorder.whereis(sid) == recorder
  end

  test "session_pid/1 exposes a live session", %{recorder: recorder} do
    assert {:ok, session} = Recorder.session_pid(recorder)
    assert Process.alive?(session)
  end

  test "an assistant frame persists text + tool rows with NO viewer attached",
       %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{
           "content" => [
             %{"type" => "text", "text" => "the answer"},
             %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls -la"}}
           ]
         }
       }}
    )

    rows = StudioChat.list_messages(sid)
    assert Enum.any?(rows, &(&1.role == "assistant" and &1.source_markdown == "the answer"))

    tool = Enum.find(rows, &(&1.role == "tool"))
    assert tool.source_markdown =~ "Bash"
    assert tool.metadata["tool"] == "Bash"
  end

  test "a result frame records metrics + status with NO viewer attached",
       %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_event,
       %{
         "type" => "result",
         "subtype" => "success",
         "total_cost_usd" => 0.03,
         "usage" => %{"input_tokens" => 500, "output_tokens" => 60},
         "modelUsage" => %{"claude-opus-4" => %{"contextWindow" => 200_000}}
       }}
    )

    s = StudioChat.get_session(sid)
    assert s.input_tokens == 500
    assert s.output_tokens == 60
    assert s.context_window == 200_000
    assert s.status == "active"
  end

  test "a permission ask persists a pending approval row", %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_permission,
       %{
         request_id: "req-1",
         tool_name: "Write",
         input: %{"file_path" => "/x"},
         title: nil,
         decision_reason: nil
       }}
    )

    assert StudioChat.get_session(sid).pending_approvals == 1
    row = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "approval"))
    assert row.metadata["approval_status"] == "pending"
    assert row.metadata["request_id"] == "req-1"
  end

  test "every frame rebroadcasts to PubSub subscribers", %{sid: sid, recorder: recorder} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    ev = %{"type" => "system", "subtype" => "status"}
    frame(recorder, {:claude_chat_event, ev})

    assert_receive {:claude_chat_event, ^ev}
  end

  test "a subprocess exit marks the session exited, cancels pendings, and broadcasts",
       %{sid: sid, recorder: recorder} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    frame(
      recorder,
      {:claude_chat_permission,
       %{request_id: "req-x", tool_name: "Bash", input: %{}, title: nil, decision_reason: nil}}
    )

    assert StudioChat.get_session(sid).pending_approvals == 1

    ref = Process.monitor(recorder)
    send(recorder, {:claude_chat_exit, 0})
    assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000

    assert_receive {:claude_chat_exit, 0}
    s = StudioChat.get_session(sid)
    assert s.status == "exited"
    assert s.pending_approvals == 0
    assert Recorder.whereis(sid) == nil
  end

  test "the idle reaper closes a silent session honestly", %{sid: sid} do
    Application.put_env(:barkpark, :studio_chat_idle_reap_ms, 60)
    on_exit(fn -> Application.delete_env(:barkpark, :studio_chat_idle_reap_ms) end)

    # a FRESH recorder arms its timer from the overridden config
    other = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: other, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: other, mode: "plan", resume: false})
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(other))

    ref = Process.monitor(recorder)
    assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
    assert_receive {:claude_chat_exit, :idle_reaped}

    assert StudioChat.get_session(other).status == "exited"
    assert Recorder.whereis(other) == nil
  end

  describe "live activity feed (wave 5)" do
    setup %{sid: sid} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      %{sid: sid}
    end

    test "a turn start (init) says working + persists the status",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      assert_receive {:chat_activity, ^sid, %{state: :working, line: "thinking…"}}
      assert StudioChat.get_session(sid).status == "working"
    end

    test "a tool_use names the concrete action; a result goes idle",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "mix test"}}
             ]
           }
         }}
      )

      assert_receive {:chat_activity, ^sid, %{state: :working, line: line}}
      assert line =~ "Bash"
      assert line =~ "mix test"

      frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      assert_receive {:chat_activity, ^sid, %{state: :idle, line: nil}}
    end

    test "a hundred stream deltas collapse into ONE writing event",
         %{sid: sid, recorder: recorder} do
      for _ <- 1..100 do
        frame(
          recorder,
          {:claude_chat_event,
           %{
             "type" => "stream_event",
             "event" => %{
               "type" => "content_block_delta",
               "delta" => %{"type" => "text_delta", "text" => "x"}
             }
           }}
        )
      end

      assert_receive {:chat_activity, ^sid, %{state: :working, line: "writing…"}}
      refute_receive {:chat_activity, ^sid, _}, 100
    end

    test "a permission ask flips the feed to needs_you", %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_permission,
         %{request_id: "r", tool_name: "Write", input: %{}, title: nil, decision_reason: nil}}
      )

      assert_receive {:chat_activity, ^sid, %{state: :needs_you, line: "waiting: Write"}}
    end

    test "an exit publishes offline", %{sid: sid, recorder: recorder} do
      ref = Process.monitor(recorder)
      send(recorder, {:claude_chat_exit, 0})
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
      assert_receive {:chat_activity, ^sid, %{state: :offline}}
    end
  end

  test "the runtime survives a viewer's death — the whole point",
       %{sid: sid, recorder: recorder} do
    # a "tab": subscribes, then dies
    parent = self()

    viewer =
      spawn(fn ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
        send(parent, :subscribed)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :subscribed
    send(viewer, :die)
    ref = Process.monitor(viewer)
    assert_receive {:DOWN, ^ref, :process, ^viewer, _}, 1_000

    # the runtime never noticed; a frame arriving NOW still persists
    frame(
      recorder,
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{"content" => [%{"type" => "text", "text" => "landed after tab close"}]}
       }}
    )

    assert Process.alive?(recorder)

    assert StudioChat.list_messages(sid)
           |> Enum.any?(&(&1.source_markdown == "landed after tab close"))
  end
end
