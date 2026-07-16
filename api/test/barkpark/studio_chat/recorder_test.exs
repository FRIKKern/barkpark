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

  # A managed-adapter stand-in for the threading test (charter D137/D110): it
  # never spawns a CLI, it just reports the opts `Runtime.open` handed it back to
  # the test process (via app-env, since it runs in the Recorder's process, not
  # the test's). The probe pid is read from app-env so the cross-process `send`
  # lands. Implements the full frozen Adapter contract.
  defmodule ProbeAdapter do
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(opts), do: notify({:runtime_start_opts, opts})
    def resume(opts), do: notify({:runtime_resume_opts, opts})
    def send_turn(_runtime, _content), do: :ok
    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, "interrupt-1"}
    def answer_approval(_runtime, _approval_id, _decision), do: :ok
    def close(_runtime), do: :ok
    def readiness(_opts), do: %{binary: true, authed?: true}
    def capabilities, do: %{modes: ["plan"], models: [], efforts: []}

    defp notify(message) do
      if pid = Application.get_env(:barkpark, :cloud_sandbox_probe_pid), do: send(pid, message)
      {:ok, :fake_runtime}
    end
  end

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

  test "a bp_sandbox frame persists the binding and is SWALLOWED (charter D137)",
       %{sid: sid, recorder: recorder} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    before = length(StudioChat.list_messages(sid))

    frame(
      recorder,
      {:claude_chat_event,
       %{"type" => "bp_sandbox", "subtype" => "created", "sandbox_id" => "sbx-x"}}
    )

    # persisted onto the Session row — the durable binding the next turn resumes
    assert StudioChat.get_session(sid).cloud_sandbox_id == "sbx-x"
    # SWALLOWED: no chat_messages row appended (the customer stream stays clean)
    assert length(StudioChat.list_messages(sid)) == before
    # SWALLOWED: never broadcast on the session topic
    refute_receive {:claude_chat_event, %{"type" => "bp_sandbox"}}, 200

    # non-vacuous: the subscription IS live — a normal frame still broadcasts, so
    # the refute above proves the swallow, not a dead topic.
    frame(
      recorder,
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
       }}
    )

    assert_receive {:claude_chat_event, %{"type" => "assistant"}}
  end

  test "the persisted Cloud sandbox binding threads into the opts handed to the runtime (D110-style)" do
    prev = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{claude: ProbeAdapter})
    Application.put_env(:barkpark, :cloud_sandbox_probe_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, prev),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)

      Application.delete_env(:barkpark, :cloud_sandbox_probe_pid)
    end)

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
    {:ok, _} = StudioChat.set_cloud_sandbox_id(id, "sbx-threaded")

    {:ok, _rec} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})

    # The recorder loads the binding from the Session row (NOT from ensure/1 opts)
    # and threads it into the map Runtime.open hands the adapter — where
    # runtime/claude.ex lifts it into ClaudeChat.command/2's session_opts (W14-1).
    assert_receive {:runtime_start_opts, opts}, 2_000
    assert opts.cloud_sandbox_id == "sbx-threaded"
    refute Map.has_key?(%{session_id: id, mode: "plan", resume: false}, :cloud_sandbox_id)
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

  test "the store is the router: AskUserQuestion persists a 'question' row (D31)",
       %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_permission,
       %{
         request_id: "q-1",
         tool_name: "AskUserQuestion",
         input: %{"questions" => [%{"question" => "Pick"}]},
         title: nil,
         decision_reason: nil
       }}
    )

    row = StudioChat.list_messages(sid) |> Enum.find(&(&1.metadata["request_id"] == "q-1"))
    assert row.role == "question"
    assert row.metadata["approval_status"] == "pending"
    # a question STILL raises the one "needs you" counter (widened role set)
    assert StudioChat.get_session(sid).pending_approvals == 1
  end

  test "the store is the router: ExitPlanMode persists a 'plan' row (D31)",
       %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_permission,
       %{
         request_id: "p-1",
         tool_name: "ExitPlanMode",
         input: %{"plan" => "# Plan\n- step"},
         title: nil,
         decision_reason: nil
       }}
    )

    row = StudioChat.list_messages(sid) |> Enum.find(&(&1.metadata["request_id"] == "p-1"))
    assert row.role == "plan"
    assert StudioChat.get_session(sid).pending_approvals == 1
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
    send(recorder, {:claude_chat_exit, 0, ""})
    assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000

    assert_receive {:claude_chat_exit, 0, _tail}
    s = StudioChat.get_session(sid)
    assert s.status == "exited"
    assert s.pending_approvals == 0
    assert Recorder.whereis(sid) == nil
  end

  test "the idle reaper closes a silent session honestly", %{sid: _sid} do
    # We drive the reap DETERMINISTICALLY by sending the `:idle_reap` tick
    # ourselves — the exact message the frame-silence timer fires — AFTER we've
    # subscribed and monitored. A short (60ms) real-timer override raced the reap
    # ahead of this setup on a loaded box: the process died before `monitor/1`,
    # so `:DOWN` carried `:noproc` not `:normal`, and the `:idle_reaped`
    # broadcast landed before the subscribe. The honest signal is the reap
    # handler itself, not the wall clock, so we exercise it directly.
    other = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: other, mode: "plan"})
    # Subscribe BEFORE the recorder exists (the topic is derived from `other`,
    # generated above) so the teardown broadcast can never be missed.
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(other))
    {:ok, recorder} = Recorder.ensure(%{session_id: other, mode: "plan", resume: false})

    ref = Process.monitor(recorder)
    send(recorder, :idle_reap)

    assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
    assert_receive {:claude_chat_exit, :idle_reaped, _tail}

    assert StudioChat.get_session(other).status == "exited"
    assert Recorder.whereis(other) == nil
  end

  describe "tool results (terminal look, w6.5)" do
    test "a tool_use persists its id; the tool_result frame attaches the output",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_abc",
                 "name" => "Bash",
                 "input" => %{"command" => "ls"}
               }
             ]
           }
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "tool"))
      assert row.metadata["tool_use_id"] == "toolu_abc"
      refute row.metadata["output"]

      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_abc",
                 "content" => "a.txt\nb.txt"
               }
             ]
           }
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "tool"))
      assert row.metadata["output"] == "a.txt\nb.txt"
    end

    test "a result for an unknown tool_use_id is a safe noop", %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{"type" => "tool_result", "tool_use_id" => "toolu_ghost", "content" => "x"}
             ]
           }
         }}
      )

      assert Process.alive?(recorder)
      assert StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "tool")) == []
    end
  end

  # A TodoWrite-shaped assistant frame (dispatch on shape, not name — the cmux
  # binary lacks TodoWrite, so we synthesize the shape). Each call is a FRESH
  # tool_use id, exactly as the real binary emits per TodoWrite.
  defp todo_frame(id, todos) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "message" => %{
         "content" => [
           %{
             "type" => "tool_use",
             "id" => id,
             "name" => "TodoWrite",
             "input" => %{"todos" => todos}
           }
         ]
       }
     }}
  end

  describe "TodoWrite living checklist collapse (charter D39)" do
    test "a SUB-AGENT's TodoWrite never hijacks the top-level card — it persists as a plain child tool row (D39×D40)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      # top-level TodoWrite opens the turn's living card
      frame(
        recorder,
        todo_frame("toolu_main", [%{"content" => "main plan", "status" => "in_progress"}])
      )

      # a sub-agent frame carrying a TodoWrite-shaped tool_use
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "toolu_spawn",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_sub",
                 "name" => "TodoWrite",
                 "input" => %{"todos" => [%{"content" => "sub plan", "status" => "pending"}]}
               }
             ]
           }
         }}
      )

      rows = StudioChat.list_messages(sid)

      # the main card is untouched…
      [todo] = Enum.filter(rows, &(&1.role == "todo"))
      assert todo.metadata["tool_use_id"] == "toolu_main"
      assert [%{"content" => "main plan"} | _] = todo.metadata["input"]["todos"]

      # …and the sub-agent's todo landed as a plain, parent-stamped tool row
      sub = Enum.find(rows, &(&1.metadata["tool_use_id"] == "toolu_sub"))
      assert sub.role == "tool"
      assert sub.metadata["parent_tool_use_id"] == "toolu_spawn"
    end

    test "two TodoWrites in ONE turn collapse to a single todo row with the latest input",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      frame(
        recorder,
        todo_frame("toolu_todo_1", [
          %{"content" => "read charter", "status" => "in_progress", "activeForm" => "reading"}
        ])
      )

      # A FRESH tool_use id (as the real binary emits) — must NOT append a 2nd row.
      frame(
        recorder,
        todo_frame("toolu_todo_2", [
          %{"content" => "read charter", "status" => "completed"},
          %{"content" => "write code", "status" => "in_progress", "activeForm" => "writing"}
        ])
      )

      todos = StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "todo"))
      assert length(todos) == 1

      [row] = todos
      # The persisted input is the LATEST state; replay reconstructs one card.
      items = row.metadata["input"]["todos"]
      assert length(items) == 2
      assert Enum.at(items, 0)["status"] == "completed"
      assert Enum.at(items, 1)["status"] == "in_progress"
      # The row keeps the FIRST TodoWrite's tool_use_id (updated in place).
      assert row.metadata["tool_use_id"] == "toolu_todo_1"
    end

    test "a new turn (init resets the tracker) starts a SEPARATE todo row",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, todo_frame("toolu_a", [%{"content" => "step", "status" => "pending"}]))

      # Second turn.
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, todo_frame("toolu_b", [%{"content" => "step", "status" => "completed"}]))

      rows = StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "todo"))
      assert length(rows) == 2
    end

    test "a non-todo tool_use is unaffected — still a plain tool row",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "t1",
                 "name" => "Bash",
                 "input" => %{"command" => "ls"}
               }
             ]
           }
         }}
      )

      rows = StudioChat.list_messages(sid)
      assert Enum.any?(rows, &(&1.role == "tool"))
      assert Enum.filter(rows, &(&1.role == "todo")) == []
    end
  end

  describe "nested agent traces (charter D40)" do
    test "a child frame stamps parent_tool_use_id on every row; a top-level frame omits it",
         %{sid: sid, recorder: recorder} do
      # Top-level: a Task spawn (its own frame has NO parent_tool_use_id).
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_spawn",
                 "name" => "Task",
                 "input" => %{
                   "description" => "Explore the recorder",
                   "prompt" => "audit it",
                   "subagent_type" => "explore"
                 }
               }
             ]
           }
         }}
      )

      # A frame emitted BY the sub-agent: top-level parent_tool_use_id set, and it
      # carries both a text block and a tool_use — BOTH rows must inherit it.
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "toolu_spawn",
           "message" => %{
             "content" => [
               %{"type" => "text", "text" => "child is thinking"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_child",
                 "name" => "Bash",
                 "input" => %{"command" => "grep -rn foo"}
               }
             ]
           }
         }}
      )

      rows = StudioChat.list_messages(sid)

      spawn_row = Enum.find(rows, &(&1.metadata["tool_use_id"] == "toolu_spawn"))
      refute spawn_row.metadata["parent_tool_use_id"]

      child_text =
        Enum.find(rows, &(&1.role == "assistant" and &1.source_markdown == "child is thinking"))

      assert child_text.metadata["parent_tool_use_id"] == "toolu_spawn"

      child_tool = Enum.find(rows, &(&1.metadata["tool_use_id"] == "toolu_child"))
      assert child_tool.metadata["parent_tool_use_id"] == "toolu_spawn"
    end

    test "an empty-string parent_tool_use_id is treated as top-level (no stamp)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "",
           "message" => %{"content" => [%{"type" => "text", "text" => "top level"}]}
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.source_markdown == "top level"))
      refute row.metadata["parent_tool_use_id"]
    end
  end

  # The wire id is a TOP-LEVEL frame uuid (charter D70; there is no message.uuid).
  # Persisting it into each row's metadata makes our message log the uuid-keyed
  # branch-point index a wave-13 fork/rewind UI replays against. "Replay
  # availability" here == the value survives the store round-trip that replay
  # reads back (`list_messages`), which is exactly the read path replay uses.
  describe "frame uuid capture (charter D70)" do
    test "an assistant frame stamps frame_uuid on every row it produces",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "uuid" => "frame-abc-123",
           "message" => %{
             "content" => [
               %{"type" => "text", "text" => "the answer"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_x",
                 "name" => "Bash",
                 "input" => %{"command" => "ls"}
               }
             ]
           }
         }}
      )

      rows = StudioChat.list_messages(sid)

      text = Enum.find(rows, &(&1.role == "assistant" and &1.source_markdown == "the answer"))
      assert text.metadata["frame_uuid"] == "frame-abc-123"

      tool = Enum.find(rows, &(&1.metadata["tool_use_id"] == "toolu_x"))
      assert tool.metadata["frame_uuid"] == "frame-abc-123"
    end

    test "frame_uuid and parent_tool_use_id coexist on a sub-agent row",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "uuid" => "frame-child-1",
           "parent_tool_use_id" => "toolu_spawn",
           "message" => %{"content" => [%{"type" => "text", "text" => "child thinking"}]}
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.source_markdown == "child thinking"))
      assert row.metadata["frame_uuid"] == "frame-child-1"
      assert row.metadata["parent_tool_use_id"] == "toolu_spawn"
    end

    test "a frame with no uuid leaves metadata unstamped (legacy/synthetic frame)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "no uuid here"}]}
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.source_markdown == "no uuid here"))
      refute Map.has_key?(row.metadata, "frame_uuid")
    end

    test "an empty-string uuid is treated as absent (no stamp)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "uuid" => "",
           "message" => %{"content" => [%{"type" => "text", "text" => "blank uuid"}]}
         }}
      )

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.source_markdown == "blank uuid"))
      refute Map.has_key?(row.metadata, "frame_uuid")
    end
  end

  describe "thinking pulse persistence (charter D41)" do
    defp thinking_tokens(n),
      do:
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "thinking_tokens", "estimated_tokens" => n}}

    defp assistant_text(text) do
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{"content" => [%{"type" => "text", "text" => text}]}
       }}
    end

    test "a thinking bout flushes a 'thinking' row BEFORE the turn's assistant blocks",
         %{sid: sid, recorder: recorder} do
      frame(recorder, thinking_tokens(40))
      frame(recorder, thinking_tokens(120))
      frame(recorder, assistant_text("the answer"))

      rows = StudioChat.list_messages(sid)
      think = Enum.find(rows, &(&1.role == "thinking"))
      answer = Enum.find(rows, &(&1.role == "assistant"))

      assert think.metadata["tokens"] == 120
      assert think.source_markdown =~ "thought for ~120 tokens"
      # order: the ✻ pulse row precedes the answer it thought toward
      assert think.seq < answer.seq
      # NEVER the signature — only the count is persisted
      refute Map.has_key?(think.metadata, "signature")
    end

    test "the count is the CUMULATIVE max, never the sum of per-frame counts",
         %{sid: sid, recorder: recorder} do
      frame(recorder, thinking_tokens(50))
      frame(recorder, thinking_tokens(90))
      frame(recorder, thinking_tokens(70))
      frame(recorder, assistant_text("done"))

      think = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "thinking"))
      # max(50,90,70) = 90 — a naive sum would be 210
      assert think.metadata["tokens"] == 90
    end

    test "no thinking frames ⇒ no thinking row", %{sid: sid, recorder: recorder} do
      frame(recorder, assistant_text("straight to prose"))
      assert StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "thinking")) == []
    end

    test "each bout flushes its own row across a multi-turn session",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, thinking_tokens(30))
      frame(recorder, assistant_text("first"))
      # a new turn opens a fresh bout
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, thinking_tokens(80))
      frame(recorder, assistant_text("second"))

      counts =
        StudioChat.list_messages(sid)
        |> Enum.filter(&(&1.role == "thinking"))
        |> Enum.map(& &1.metadata["tokens"])

      assert counts == [30, 80]
    end

    test "a new turn's init drops a stale unflushed bout", %{sid: sid, recorder: recorder} do
      frame(recorder, thinking_tokens(45))
      # init before any assistant block: the bout never produced output, so the
      # next turn's init resets it and it leaves no row.
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, assistant_text("fresh turn, no prior thought"))

      assert StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "thinking")) == []
    end

    test "a thinking_tokens frame rebroadcasts to subscribers", %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      frame(recorder, thinking_tokens(12))

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "system",
                        "subtype" => "thinking_tokens",
                        "estimated_tokens" => 12
                      }}
    end
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

    test "the needs-you line reads by role: 'asking you' / 'plan ready' (D35)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_permission,
         %{
           request_id: "q",
           tool_name: "AskUserQuestion",
           input: %{"questions" => []},
           title: nil,
           decision_reason: nil
         }}
      )

      assert_receive {:chat_activity, ^sid, %{state: :needs_you, line: "asking you"}}

      frame(
        recorder,
        {:claude_chat_permission,
         %{
           request_id: "p",
           tool_name: "ExitPlanMode",
           input: %{"plan" => "x"},
           title: nil,
           decision_reason: nil
         }}
      )

      assert_receive {:chat_activity, ^sid, %{state: :needs_you, line: "plan ready"}}
    end

    test "an exit publishes offline", %{sid: sid, recorder: recorder} do
      ref = Process.monitor(recorder)
      send(recorder, {:claude_chat_exit, 0, ""})
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
      assert_receive {:chat_activity, ^sid, %{state: :offline}}
    end
  end

  describe "slash-command handshake (charter D36a)" do
    test "the initialize ack is HELD so a late-joining tab still gets the list",
         %{recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_control, :initialize, "bp-req-x",
         %{
           "commands" => [
             %{"name" => "compact", "description" => "Compact", "argumentHint" => nil}
           ]
         }}
      )

      # A tab that opens AFTER the ack fired reads the held vocabulary directly.
      assert [%{"name" => "compact"}] = Recorder.advertised_commands(recorder)
    end

    test "the ack broadcasts the vocabulary to a subscribed tab",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        {:claude_chat_control, :initialize, "bp-req-y", %{"commands" => [%{"name" => "review"}]}}
      )

      assert_receive {:chat_commands, ^sid, [%{"name" => "review"}]}
    end

    test "system/init slash_commands is the name-only FALLBACK when no ack landed",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "slash_commands" => ["clear", "cost"]}}
      )

      assert_receive {:chat_commands, ^sid, cmds}
      assert Enum.map(cmds, & &1["name"]) == ["clear", "cost"]
      assert [%{"name" => "clear"} | _] = Recorder.advertised_commands(recorder)
    end

    test "the rich ack OVERRIDES the name-only fallback", %{recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "slash_commands" => ["clear"]}}
      )

      frame(
        recorder,
        {:claude_chat_control, :initialize, "bp-req-z",
         %{"commands" => [%{"name" => "compact", "description" => "rich"}]}}
      )

      assert [%{"name" => "compact", "description" => "rich"}] =
               Recorder.advertised_commands(recorder)
    end
  end

  describe "agent lifecycle: task_* frames stamp the spawn row (charter D45)" do
    # A Task/Agent spawn persists as a plain tool row keyed by its tool_use_id —
    # exactly what the assistant-frame path already writes.
    defp spawn_frame(tool_use_id) do
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => tool_use_id,
               "name" => "Task",
               "input" => %{
                 "description" => "Count files",
                 "prompt" => "count them",
                 "subagent_type" => "general-purpose"
               }
             }
           ]
         }
       }}
    end

    defp task_event(subtype, fields),
      do: {:claude_chat_event, Map.merge(%{"type" => "system", "subtype" => subtype}, fields)}

    defp spawn_row(sid, tool_use_id),
      do:
        StudioChat.list_messages(sid)
        |> Enum.find(&(&1.metadata["tool_use_id"] == tool_use_id))

    test "task_started stamps task_id + running onto the spawn row, preserving its input",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_started", %{
          "task_id" => "task-1",
          "tool_use_id" => "toolu_spawn",
          "subagent_type" => "general-purpose",
          "description" => "Count files in directory"
        })
      )

      row = spawn_row(sid, "toolu_spawn")
      assert row.metadata["task_id"] == "task-1"
      assert row.metadata["task_status"] == "running"
      # the merge NEVER clobbers the spawn's own input (the D45 anti-pattern)
      assert row.metadata["input"]["description"] == "Count files"
      assert row.metadata["input"]["subagent_type"] == "general-purpose"
      assert row.metadata["tool"] == "Task"
    end

    test "task_progress stamps the live line; task_notification stamps the terminal status",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_spawn"})
      )

      frame(
        recorder,
        task_event("task_progress", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "description" => "Running the count"
        })
      )

      assert spawn_row(sid, "toolu_spawn").metadata["task_progress"] == "Running the count"

      frame(
        recorder,
        task_event("task_notification", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "status" => "completed",
          "summary" => "9 files"
        })
      )

      row = spawn_row(sid, "toolu_spawn")
      assert row.metadata["task_status"] == "completed"
      # the running progress line is preserved through the terminal merge
      assert row.metadata["task_progress"] == "Running the count"
    end

    test "task_progress persists COARSELY — an unchanged line does not rewrite the row",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_spawn"})
      )

      frame(
        recorder,
        task_event("task_progress", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "description" => "L1"
        })
      )

      # Externally poison the row's line, then send the SAME progress line again.
      # A coarse writer (line unchanged since last persist) must NOT overwrite it.
      {:ok, _} =
        StudioChat.merge_tool_metadata(sid, "toolu_spawn", %{"task_progress" => "SENTINEL"})

      frame(
        recorder,
        task_event("task_progress", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "description" => "L1"
        })
      )

      assert spawn_row(sid, "toolu_spawn").metadata["task_progress"] == "SENTINEL"

      # A genuinely CHANGED line does write through.
      frame(
        recorder,
        task_event("task_progress", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "description" => "L2"
        })
      )

      assert spawn_row(sid, "toolu_spawn").metadata["task_progress"] == "L2"
    end

    test "task_updated (task_id ONLY) resolves the spawn row via the session-lifetime index",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_spawn"})
      )

      # a NEW turn begins between start and completion — the index must survive it
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      frame(
        recorder,
        task_event("task_updated", %{
          "task_id" => "t",
          "patch" => %{"status" => "completed", "end_time" => 1}
        })
      )

      assert spawn_row(sid, "toolu_spawn").metadata["task_status"] == "completed"
    end

    test "task_updated for an unknown task_id drops harmlessly", %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_updated", %{"task_id" => "ghost", "patch" => %{"status" => "completed"}})
      )

      assert Process.alive?(recorder)
      refute spawn_row(sid, "toolu_spawn").metadata["task_status"]
    end

    test "a task frame for an unknown tool_use_id is a safe noop", %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_ghost"})
      )

      assert Process.alive?(recorder)
      assert StudioChat.merge_tool_metadata(sid, "toolu_ghost", %{"x" => 1}) == :noop
    end

    test "every task_* frame rebroadcasts verbatim to subscribers", %{
      sid: sid,
      recorder: recorder
    } do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      ev = %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "t",
        "tool_use_id" => "x"
      }

      frame(recorder, {:claude_chat_event, ev})
      assert_receive {:claude_chat_event, ^ev}
    end

    test "teardown flips a still-running task to interrupted (all death paths)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_spawn"))

      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_spawn"})
      )

      assert spawn_row(sid, "toolu_spawn").metadata["task_status"] == "running"

      ref = Process.monitor(recorder)
      send(recorder, {:claude_chat_exit, 0, ""})
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000

      assert spawn_row(sid, "toolu_spawn").metadata["task_status"] == "interrupted"
    end

    test "interrupt_running_tasks/1 only touches running rows, preserving other metadata",
         %{sid: sid, recorder: recorder} do
      frame(recorder, spawn_frame("toolu_a"))
      frame(recorder, spawn_frame("toolu_b"))
      frame(recorder, task_event("task_started", %{"task_id" => "a", "tool_use_id" => "toolu_a"}))

      frame(
        recorder,
        task_event("task_notification", %{
          "task_id" => "b",
          "tool_use_id" => "toolu_b",
          "status" => "completed"
        })
      )

      assert StudioChat.interrupt_running_tasks(sid) == 1

      assert spawn_row(sid, "toolu_a").metadata["task_status"] == "interrupted"
      # the already-completed task is untouched, and its input survives
      assert spawn_row(sid, "toolu_b").metadata["task_status"] == "completed"
      assert spawn_row(sid, "toolu_a").metadata["input"]["prompt"] == "count them"
    end

    test "task_* frames never feed the sidebar activity surface (charter D45)",
         %{sid: sid, recorder: recorder} do
      # The drill-down is a transcript surface — a chatty sub-agent's heartbeat
      # must not flicker the sidebar's activity line.
      frame(recorder, spawn_frame("toolu_spawn"))
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      frame(
        recorder,
        task_event("task_started", %{"task_id" => "t", "tool_use_id" => "toolu_spawn"})
      )

      frame(
        recorder,
        task_event("task_progress", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "description" => "Running"
        })
      )

      frame(
        recorder,
        task_event("task_notification", %{
          "task_id" => "t",
          "tool_use_id" => "toolu_spawn",
          "status" => "completed"
        })
      )

      refute_receive {:chat_activity, ^sid, _}, 100
    end
  end

  describe "agents rail: background_tasks_changed + workflow_progress (charter D47)" do
    defp bg_frame(tasks),
      do:
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "background_tasks_changed", "tasks" => tasks}}

    defp progress_frame(fields),
      do:
        {:claude_chat_event,
         Map.merge(%{"type" => "system", "subtype" => "task_progress"}, fields)}

    defp session_rail(sid), do: StudioChat.get_session(sid).rail_snapshot || %{}

    test "background_tasks_changed persists a task_id-keyed row; a vanished task completes",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([
          %{"task_id" => "a", "task_type" => "local_workflow", "description" => "Build the rail"},
          %{"task_id" => "b", "task_type" => "local_workflow", "description" => "Write the tests"}
        ])
      )

      rail = session_rail(sid)
      assert rail["a"]["row"]["description"] == "Build the rail"
      assert rail["a"]["status"] == "running"
      assert rail["b"]["status"] == "running"

      # "a" vanishes from the snapshot → it completed; entries are never deleted.
      frame(
        recorder,
        bg_frame([
          %{"task_id" => "b", "task_type" => "local_workflow", "description" => "Write the tests"}
        ])
      )

      rail = session_rail(sid)
      assert rail["a"]["status"] == "completed"
      assert rail["b"]["status"] == "running"
    end

    test "rail_snapshot is SESSION-LIFETIME — it survives a system/init turn boundary",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([
          %{"task_id" => "a", "task_type" => "local_workflow", "description" => "long agent"}
        ])
      )

      # a fresh turn begins mid-run — the rail must NOT reset (unlike per-turn state)
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      assert session_rail(sid)["a"]["status"] == "running"
    end

    test "task_progress captures workflow_progress; a token-only tick does NOT re-persist",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      frame(
        recorder,
        progress_frame(%{
          "task_id" => "t",
          "workflow_progress" => [
            %{"type" => "workflow_phase", "title" => "Plan"},
            %{
              "type" => "workflow_agent",
              "label" => "explorer",
              "model" => "fable",
              "state" => "running",
              "tokens" => 10
            }
          ],
          "usage" => %{"total_tokens" => 10}
        })
      )

      assert get_in(session_rail(sid), ["t", "workflow"]) |> Enum.at(1) |> Map.get("label") ==
               "explorer"

      # Poison the persisted column, then send a TOKEN-ONLY tick (same tree
      # structure + states, only tokens advanced). A coarse writer must NOT
      # overwrite the sentinel — the structural signature is unchanged.
      {:ok, _} = StudioChat.set_rail_snapshot(sid, %{"SENTINEL" => %{"status" => "running"}})

      frame(
        recorder,
        progress_frame(%{
          "task_id" => "t",
          "workflow_progress" => [
            %{"type" => "workflow_phase", "title" => "Plan"},
            %{
              "type" => "workflow_agent",
              "label" => "explorer",
              "model" => "fable",
              "state" => "running",
              "tokens" => 9_999
            }
          ],
          "usage" => %{"total_tokens" => 9_999}
        })
      )

      assert Map.has_key?(session_rail(sid), "SENTINEL"),
             "a token-only tick re-persisted the rail — the change-only guard failed"

      # A genuine STRUCTURAL change (agent state → completed) persists through.
      frame(
        recorder,
        progress_frame(%{
          "task_id" => "t",
          "workflow_progress" => [
            %{"type" => "workflow_phase", "title" => "Plan"},
            %{
              "type" => "workflow_agent",
              "label" => "explorer",
              "model" => "fable",
              "state" => "completed",
              "tokens" => 9_999
            }
          ]
        })
      )

      refute Map.has_key?(session_rail(sid), "SENTINEL")

      assert get_in(session_rail(sid), ["t", "workflow"]) |> Enum.at(1) |> Map.get("state") ==
               "completed"
    end

    test "task_notification / task_updated stamp the rail entry's status",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      frame(
        recorder,
        task_event("task_updated", %{"task_id" => "t", "patch" => %{"status" => "completed"}})
      )

      assert session_rail(sid)["t"]["status"] == "completed"
    end

    test "a lifecycle status frame for a task with NO rail entry drops harmlessly",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        task_event("task_updated", %{"task_id" => "ghost", "patch" => %{"status" => "completed"}})
      )

      refute Map.has_key?(session_rail(sid), "ghost")
    end

    test "interrupt_running_tasks/1 flips running rail entries to interrupted",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([
          %{"task_id" => "live", "task_type" => "local_workflow", "description" => "still going"}
        ])
      )

      # a second task that already completed must stay completed
      frame(
        recorder,
        bg_frame([
          %{"task_id" => "live", "task_type" => "local_workflow", "description" => "still going"},
          %{"task_id" => "done", "task_type" => "local_workflow", "description" => "finished"}
        ])
      )

      frame(
        recorder,
        task_event("task_notification", %{"task_id" => "done", "status" => "completed"})
      )

      StudioChat.interrupt_running_tasks(sid)

      rail = session_rail(sid)
      assert rail["live"]["status"] == "interrupted"
      assert rail["done"]["status"] == "completed"
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

  describe "mcp loopback (charter D64/D65 — scc-w12-mcp-loopback)" do
    test "a loopback tool row is TAGGED in persisted metadata (S5 consumes this)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu-mcp-1",
                 "name" => "mcp__barkpark__task_ready",
                 "input" => %{}
               },
               %{
                 "type" => "tool_use",
                 "id" => "tu-plain-1",
                 "name" => "Bash",
                 "input" => %{"command" => "ls"}
               }
             ]
           }
         }}
      )

      rows = StudioChat.list_messages(sid)

      mcp_row = Enum.find(rows, &(&1.metadata["tool_use_id"] == "tu-mcp-1"))
      assert mcp_row.role == "tool"
      assert mcp_row.metadata["mcp"] == true
      assert mcp_row.metadata["mcp_tool"] == "task_ready"
      # the FULL wire name stays in "tool" — S5 dispatches on OUR names (D64)
      assert mcp_row.metadata["tool"] == "mcp__barkpark__task_ready"

      # a non-loopback row's metadata is byte-unchanged: no mcp keys
      plain = Enum.find(rows, &(&1.metadata["tool_use_id"] == "tu-plain-1"))
      refute Map.has_key?(plain.metadata, "mcp")
      refute Map.has_key?(plain.metadata, "mcp_tool")
    end

    test "a READ-ONLY loopback ask auto-approves: allow hits the wire; no card, no needs-you",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      frame(
        recorder,
        {:claude_chat_permission,
         %{
           request_id: "mcp-r1",
           tool_name: "mcp__barkpark__task_ready",
           input: %{},
           title: nil,
           decision_reason: nil
         }}
      )

      # the allow reached the wire: the `cat` fake echoes the Session's
      # control_response straight back, and the Recorder rebroadcasts it
      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "request_id" => "mcp-r1",
                          "response" => %{"behavior" => "allow"}
                        }
                      }},
                     2_000

      # never surfaced as an ask: no broadcast card, no pending row, no
      # needs-you flip — live and replay agree it was never the human's
      refute_receive {:claude_chat_permission, _}, 100
      refute_receive {:chat_activity, _, %{state: :needs_you}}, 100
      assert StudioChat.get_session(sid).pending_approvals == 0
      assert StudioChat.list_messages(sid) == []
    end

    test "a MUTATING loopback ask still persists the pending card and flips needs-you",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      frame(
        recorder,
        {:claude_chat_permission,
         %{
           request_id: "mcp-w1",
           tool_name: "mcp__barkpark__bp_doc_create",
           input: %{"type" => "task"},
           title: nil,
           decision_reason: nil
         }}
      )

      # the honest approval card: broadcast + persisted pending + needs-you
      assert_receive {:claude_chat_permission, %{request_id: "mcp-w1"}}
      assert_receive {:chat_activity, _, %{state: :needs_you}}
      assert StudioChat.get_session(sid).pending_approvals == 1

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.metadata["request_id"] == "mcp-w1"))
      assert row.role == "approval"
      assert row.metadata["approval_status"] == "pending"
    end
  end
end
