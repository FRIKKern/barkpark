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
  alias Barkpark.StudioChat.{AgentStateSweeper, Recorder, Session}
  alias Barkpark.StudioChat.Runtime.Event

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

  # The Recorder is the SOURCE OF TRUTH for "this row's turn settled"
  # (task-d5083ae525902f28). It stamps at the turn's terminal `result` frame, so
  # BOTH replay surfaces read the same fact off the row: Studio's replay_message
  # and the Go TUI's toolRowGlyph (message_json ships metadata verbatim). Nothing
  # is derived from a live-only turn boundary the store cannot reconstruct.
  describe "settle stamping at the result frame (settle-gated gutter)" do
    defp settle_tool_frame(id, name, input) do
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{
           "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
         }
       }}
    end

    defp settle_result_frame(id, content, error?) do
      block =
        %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
        |> then(fn b -> if error?, do: Map.put(b, "is_error", true), else: b end)

      {:claude_chat_event, %{"type" => "user", "message" => %{"content" => [block]}}}
    end

    defp settle_row(sid, id) do
      StudioChat.list_messages(sid) |> Enum.find(&(&1.metadata["tool_use_id"] == id))
    end

    test "a tool row is UNSETTLED until its turn's result frame lands",
         %{sid: sid, recorder: recorder} do
      frame(recorder, settle_tool_frame("toolu_s1", "Bash", %{"command" => "ls"}))
      frame(recorder, settle_result_frame("toolu_s1", "a.txt", false))

      # The output is attached, but the TURN has not ended — the row must not
      # claim completion yet (the settle gate, persisted half).
      row = settle_row(sid, "toolu_s1")
      assert row.metadata["output"] == "a.txt"
      refute row.metadata["turn_settled"]

      frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

      assert settle_row(sid, "toolu_s1").metadata["turn_settled"] == true
    end

    test "an is_error tool_result persists tool_error so a REPLAY draws ✗, not ✓",
         %{sid: sid, recorder: recorder} do
      frame(recorder, settle_tool_frame("toolu_s2", "Bash", %{"command" => "false"}))
      frame(recorder, settle_result_frame("toolu_s2", "boom", true))
      frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

      meta = settle_row(sid, "toolu_s2").metadata
      assert meta["tool_error"] == true
      assert meta["turn_settled"] == true
    end

    test "an is_error result with NO text still persists — an empty error is not a silent drop",
         %{sid: sid, recorder: recorder} do
      frame(recorder, settle_tool_frame("toolu_s3", "Bash", %{"command" => "false"}))
      # `content` absent entirely: result_text/1 answers nil, which the seam
      # normalizes to "" rather than raising on the is_binary(output) guard.
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{"type" => "tool_result", "tool_use_id" => "toolu_s3", "is_error" => true}
             ]
           }
         }}
      )

      assert Process.alive?(recorder)
      meta = settle_row(sid, "toolu_s3").metadata
      assert meta["tool_error"] == true
      assert meta["output"] == ""
    end

    test "a row whose result never arrived is SETTLED but resultless — the provenance gate's input",
         %{sid: sid, recorder: recorder} do
      frame(recorder, settle_tool_frame("toolu_s4", "Bash", %{"command" => "sleep 9000"}))
      frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

      meta = settle_row(sid, "toolu_s4").metadata
      assert meta["turn_settled"] == true
      # No output was ever attached — the renderers' provenance gate reads this
      # absence and keeps the row neutral rather than fabricating a ✓.
      refute Map.has_key?(meta, "output")
      refute Map.has_key?(meta, "tool_error")
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

  describe "agents rail → {:chat_workflow} broadcast (charter D5–D7)" do
    defp workflow_progress(tid, state, opts \\ []) do
      tokens = Keyword.get(opts, :tokens, 10)

      progress_frame(%{
        "task_id" => tid,
        "workflow_progress" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Plan"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "explorer",
            "model" => "fable",
            "state" => state,
            "startedAt" => 1_782_767_557_221,
            "tokens" => tokens
          }
        ],
        "usage" => %{"total_tokens" => tokens}
      })
    end

    test "a workflow-bearing structural change broadcasts {:chat_workflow}; token-only ticks emit none",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      # A background-only rail change carries no workflow node ⇒ zero broadcasts.
      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      refute_receive {:chat_workflow, ^sid, _}, 100

      # The FIRST workflow tree is a structural change ⇒ exactly one broadcast.
      frame(recorder, workflow_progress("t", "running"))

      assert_receive {:chat_workflow, ^sid, summary}, 200
      assert summary.agents_total == 1
      assert summary.running == 1
      assert summary.agents_done == 0
      assert summary.label == "run"
      assert summary.terminal? == false
      refute_receive {:chat_workflow, ^sid, _}, 100

      # Two token-only ticks (same tree + states, only tokens advance) leave the
      # structural signature untouched ⇒ ZERO additional broadcasts (charter D6).
      frame(recorder, workflow_progress("t", "running", tokens: 500))
      frame(recorder, workflow_progress("t", "running", tokens: 9_999))
      refute_receive {:chat_workflow, ^sid, _}, 100

      # A genuine state flip (running → completed) is one structural change ⇒
      # exactly one further broadcast, now carrying the settled counts.
      frame(recorder, workflow_progress("t", "completed", tokens: 9_999))

      assert_receive {:chat_workflow, ^sid, settled}, 200
      assert settled.running == 0
      assert settled.agents_done == 1
      refute_receive {:chat_workflow, ^sid, _}, 100
    end

    test "the summary ALSO rides the per-session topic (the SSE wire) and NEVER leaks cross-session (wsc-bl-workflow-sse, D22)",
         %{sid: sid, recorder: recorder} do
      # A SECOND session — its per-session topic is a leak tripwire.
      other = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: other, mode: "plan"})

      # The Studio sidebar keys off the GLOBAL activity topic; the SSE forwarder
      # keys off THIS session's per-session topic — both must fire.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      # …and the OTHER session's topic — session B must never see session A.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(other))

      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      frame(recorder, workflow_progress("t", "running"))

      # The activity topic fires (Studio, unchanged)…
      assert_receive {:chat_workflow, ^sid, summary_activity}, 200
      # …AND the per-session topic fires the SAME summary (the SSE wire, D22).
      assert_receive {:chat_workflow, ^sid, summary_session}, 200
      assert summary_activity == summary_session
      assert summary_session.label == "run"

      # Tenant-safe BY CONSTRUCTION: topic(other) embeds a DIFFERENT sid, so a
      # subscriber on session B's stream never receives session A's workflow — no
      # ^id filter needed (the topic key IS the scope).
      refute_receive {:chat_workflow, ^other, _}, 100
    end

    test "task_updated folds patch.end_time onto the rail entry; workflow_summary surfaces ended_at (charter D5)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      frame(recorder, workflow_progress("t", "completed"))

      # Before the terminal patch there is no end_time and ended_at is nil.
      refute Map.has_key?(session_rail(sid)["t"], "end_time")
      assert StudioChat.workflow_summary(session_rail(sid)).ended_at == nil

      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      frame(
        recorder,
        task_event("task_updated", %{
          "task_id" => "t",
          "patch" => %{"status" => "completed", "end_time" => 1_782_767_600_000}
        })
      )

      # The persisted entry now carries the terminal end_time…
      assert session_rail(sid)["t"]["end_time"] == 1_782_767_600_000
      # …and workflow_summary/1 surfaces it as a real ended_at.
      assert StudioChat.workflow_summary(session_rail(sid)).ended_at == 1_782_767_600_000

      # Stamping the terminal status was a structural change ⇒ the broadcast
      # carries the same real ended_at to every subscribed card.
      assert_receive {:chat_workflow, ^sid, summary}, 200
      assert summary.ended_at == 1_782_767_600_000
      assert summary.terminal? == true
    end

    test "plain chats pay zero: a session whose rail never carries workflow nodes never broadcasts {:chat_workflow}",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      # A pure text turn — no rail at all.
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "hello"}]}
         }}
      )

      # A background-task lifecycle that moves the rail but never carries a
      # workflow node list — still zero {:chat_workflow}.
      frame(
        recorder,
        bg_frame([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "run"}])
      )

      frame(
        recorder,
        task_event("task_updated", %{"task_id" => "t", "patch" => %{"status" => "completed"}})
      )

      refute_receive {:chat_workflow, ^sid, _}, 150
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

  # ── agent_state substrate (herd wave 1, charter D38–D43h) ──────────────────

  describe "agent_state persistence at the publish_activity seam (D38/D39)" do
    setup %{sid: sid} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      %{sid: sid}
    end

    defp init_frame, do: {:claude_chat_event, %{"type" => "system", "subtype" => "init"}}

    defp result_frame,
      do: {:claude_chat_event, %{"type" => "result", "subtype" => "success"}}

    defp ask_frame(rid, tool \\ "Write") do
      {:claude_chat_permission,
       %{request_id: rid, tool_name: tool, input: %{}, title: nil, decision_reason: nil}}
    end

    defp tool_frame(command) do
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{
           "content" => [
             %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => command}}
           ]
         }
       }}
    end

    defp delta_frame do
      {:claude_chat_event,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => "x"}
         }
       }}
    end

    defp agent_state(sid), do: StudioChat.get_session(sid).agent_state

    test "init→working, ask→blocked, resolve→working, result→idle — all persisted",
         %{sid: sid, recorder: recorder} do
      # no backfill: a fresh row is the schema default with a NULL stamp
      s0 = StudioChat.get_session(sid)
      assert s0.agent_state == "idle"
      assert s0.agent_state_at == nil

      frame(recorder, init_frame())
      s1 = StudioChat.get_session(sid)
      assert s1.agent_state == "working"
      assert %DateTime{} = s1.agent_state_at

      frame(recorder, ask_frame("as-r1"))
      assert agent_state(sid) == "blocked"

      # resolving the ONLY pending ask unblocks the persisted state — Studio's
      # resolve_permission and the /v1/chat approval route both funnel here
      {:ok, _} = StudioChat.update_approval_status(sid, "as-r1", "allowed")
      assert agent_state(sid) == "working"

      frame(recorder, result_frame())
      assert agent_state(sid) == "idle"
    end

    test "flips-only: 100 deltas + tool line-text churn cause ZERO extra writes",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      %{agent_state: "working", agent_state_at: at0} = StudioChat.get_session(sid)

      for _ <- 1..100, do: frame(recorder, delta_frame())

      # line-text-only churn: "Bash — x" → "Bash — y" IS an activity change
      # (it broadcasts) but both map to "working" — never a store write
      frame(recorder, tool_frame("mix test a"))
      frame(recorder, tool_frame("mix test b"))

      assert_receive {:chat_activity, ^sid,
                      %{state: :working, line: "Bash — command: mix test a"}}

      assert_receive {:chat_activity, ^sid,
                      %{state: :working, line: "Bash — command: mix test b"}}

      # every set_agent_state write refreshes agent_state_at, so an unchanged
      # stamp PROVES zero writes since the single init flip (the write-count)
      %{agent_state: "working", agent_state_at: at1} = StudioChat.get_session(sid)
      assert DateTime.compare(at0, at1) == :eq
    end

    test "offline after working → unknown (mid-turn death, D39)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      ref = Process.monitor(recorder)
      send(recorder, {:claude_chat_exit, 1, "boom"})
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
      assert agent_state(sid) == "unknown"
    end

    test "offline after a pending ask (needs_you) → unknown (D39)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      frame(recorder, ask_frame("as-r2"))
      ref = Process.monitor(recorder)
      send(recorder, {:claude_chat_exit, 0, ""})
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
      assert agent_state(sid) == "unknown"
    end

    test "idle_reap of a RESTING session stays idle — a reaped rest is not wedged (D39)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      frame(recorder, result_frame())
      %{agent_state: "idle", agent_state_at: at0} = StudioChat.get_session(sid)

      ref = Process.monitor(recorder)
      send(recorder, :idle_reap)
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000

      # STAYS idle, and flips-only means the reap wrote nothing at all
      %{agent_state: "idle", agent_state_at: at1} = StudioChat.get_session(sid)
      assert DateTime.compare(at0, at1) == :eq
    end

    test "idle_reap MID-TURN → unknown (the reaper can fire during a turn, D39)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      ref = Process.monitor(recorder)
      send(recorder, :idle_reap)
      assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}, 2_000
      assert agent_state(sid) == "unknown"
    end

    test "the codex runtime-event path drives the SAME persisted states",
         %{sid: sid, recorder: recorder} do
      ev = fn kind -> %Event{kind: kind, provider: "codex", session_id: sid} end

      frame(recorder, {:studio_chat_runtime_event, ev.(:turn_started)})
      %{agent_state: "working", agent_state_at: at0} = StudioChat.get_session(sid)

      # deltas collapse: same mapped state ⇒ zero further writes
      for _ <- 1..100, do: frame(recorder, {:studio_chat_runtime_event, ev.(:text_delta)})
      %{agent_state: "working", agent_state_at: at1} = StudioChat.get_session(sid)
      assert DateTime.compare(at0, at1) == :eq

      # a codex approval ask flips blocked (the :approval_requested branch)
      frame(
        recorder,
        {:studio_chat_runtime_event,
         %Event{
           kind: :approval_requested,
           provider: "codex",
           session_id: sid,
           approval_id: "cdx-1",
           native: %{"method" => "item/commandExecution/requestApproval", "params" => %{}}
         }}
      )

      assert agent_state(sid) == "blocked"

      frame(recorder, {:studio_chat_runtime_event, ev.(:turn_completed)})
      assert agent_state(sid) == "idle"

      # the codex error path is an :offline site: prior working → unknown
      frame(recorder, {:studio_chat_runtime_event, ev.(:turn_started)})
      assert agent_state(sid) == "working"
      frame(recorder, {:studio_chat_runtime_event, ev.(:error)})
      assert agent_state(sid) == "unknown"
    end
  end

  # ── blocked-truth guard (charter D56h, herd-s3f) ────────────────────────────
  #
  # Reproduced 3/3 live: the instant an ask fires, a trailing assistant
  # tool_use frame re-derives :working and clobbers :needs_you 1.3–2.7ms later
  # while the ask stays genuinely pending — blocked was observable for
  # milliseconds only. The guard lives at the publish_activity seam: an
  # activity-derived :working never overwrites blocked while any pending ask
  # remains; resolution (answer / cancel / exit) still unblocks.
  describe "blocked-truth guard — a pending ask keeps agent_state=blocked (D56h)" do
    setup %{sid: sid} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      %{sid: sid}
    end

    test "a late assistant tool_use frame never clobbers blocked; resolve → working",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      assert_receive {:chat_activity, ^sid, %{state: :working, line: "thinking…"}}

      frame(recorder, ask_frame("bt-1", "Bash"))
      assert_receive {:chat_activity, ^sid, %{state: :needs_you}}
      assert agent_state(sid) == "blocked"

      # THE CLOBBER: a trailing/duplicate assistant tool_use frame lands
      # microseconds after the ask while it is still genuinely pending
      frame(recorder, tool_frame("mix test"))
      assert agent_state(sid) == "blocked"
      refute_receive {:chat_activity, ^sid, %{state: :working}}, 100

      # stream deltas derive :working too — same guard, same suppression
      frame(recorder, delta_frame())
      assert agent_state(sid) == "blocked"

      # resolving the ask (Studio + /v1/chat both funnel through
      # update_approval_status) flips the store, and the NEXT working frame
      # passes the guard so the live overlay converges too
      {:ok, _} = StudioChat.update_approval_status(sid, "bt-1", "allowed")
      assert agent_state(sid) == "working"

      frame(recorder, tool_frame("mix test again"))
      assert_receive {:chat_activity, ^sid, %{state: :working}}
      assert agent_state(sid) == "working"
    end

    test "a second ask keeps blocked until the LAST resolves",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      assert_receive {:chat_activity, ^sid, %{state: :working, line: "thinking…"}}

      frame(recorder, ask_frame("bt-a", "Write"))
      frame(recorder, ask_frame("bt-b", "AskUserQuestion"))
      assert agent_state(sid) == "blocked"

      # first resolution: one ask still pending — aligned with
      # unblock_if_resolved's pending==0 guard, blocked holds
      {:ok, _} = StudioChat.update_approval_status(sid, "bt-a", "allowed")
      assert agent_state(sid) == "blocked"

      frame(recorder, tool_frame("mix deps.get"))
      assert agent_state(sid) == "blocked"
      refute_receive {:chat_activity, ^sid, %{state: :working}}, 100

      # the LAST resolution unblocks; the next working frame flows through
      {:ok, _} = StudioChat.update_approval_status(sid, "bt-b", "denied")
      assert agent_state(sid) == "working"

      frame(recorder, tool_frame("mix test"))
      assert_receive {:chat_activity, ^sid, %{state: :working}}
      assert agent_state(sid) == "working"
    end

    test "cancel_pending_approvals unblocks: the next working frame flows",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      frame(recorder, ask_frame("bt-c"))
      assert agent_state(sid) == "blocked"

      # the force-cancel teardown zeroes the pending counter; the guard reads
      # that store truth and lets the wire's working through again
      StudioChat.cancel_pending_approvals(sid)
      frame(recorder, tool_frame("mix test"))
      assert agent_state(sid) == "working"
    end

    test "suppression writes NOTHING (flips-only discipline intact)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, init_frame())
      frame(recorder, ask_frame("bt-d"))
      %{agent_state: "blocked", agent_state_at: at0} = StudioChat.get_session(sid)

      for _ <- 1..20, do: frame(recorder, delta_frame())
      frame(recorder, tool_frame("mix a"))
      frame(recorder, tool_frame("mix b"))

      # an unchanged stamp PROVES zero writes while suppressed (every
      # set_agent_state write refreshes agent_state_at)
      %{agent_state: "blocked", agent_state_at: at1} = StudioChat.get_session(sid)
      assert DateTime.compare(at0, at1) == :eq
    end

    test "codex: a text_delta after :approval_requested keeps blocked until resolve",
         %{sid: sid, recorder: recorder} do
      ev = fn kind -> %Event{kind: kind, provider: "codex", session_id: sid} end

      frame(recorder, {:studio_chat_runtime_event, ev.(:turn_started)})

      frame(
        recorder,
        {:studio_chat_runtime_event,
         %Event{
           kind: :approval_requested,
           provider: "codex",
           session_id: sid,
           approval_id: "bt-cdx",
           native: %{"method" => "item/commandExecution/requestApproval", "params" => %{}}
         }}
      )

      assert agent_state(sid) == "blocked"

      frame(recorder, {:studio_chat_runtime_event, ev.(:text_delta)})
      assert agent_state(sid) == "blocked"

      {:ok, _} = StudioChat.update_approval_status(sid, "bt-cdx", "allowed")
      frame(recorder, {:studio_chat_runtime_event, ev.(:text_delta)})
      assert agent_state(sid) == "working"
    end
  end

  describe "autopilot policy (plan-approve auto-switch)" do
    test "the plan-approved fact engages Autopilot: persist + broadcast",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(recorder, {:claude_chat_plan_approved, "req-plan"})

      # Persisted: the next lazy --resume spawns in Autopilot.
      assert StudioChat.get_session(sid).mode == "auto"
      # Broadcast: every live viewer (Studio tab, SSE forwarder) flips now.
      assert_receive {:studio_chat_mode_adopted, "auto", :plan_approved}, 1_000
    end

    test "init reporting permissionMode default while the store says plan engages (safety net)",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "default"}}
      )

      assert StudioChat.get_session(sid).mode == "auto"
      assert_receive {:studio_chat_mode_adopted, "auto", :plan_approved}, 1_000
    end

    test "a routine init (mode matching the store) adopts nothing",
         %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "plan"}}
      )

      assert StudioChat.get_session(sid).mode == "plan"
      refute_receive {:studio_chat_mode_adopted, _, _}, 200
    end

    test "a genuine legacy-default session stays untouched (no silent escalation)",
         %{sid: sid, recorder: recorder} do
      StudioChat.set_mode(sid, "default")
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "default"}}
      )

      assert StudioChat.get_session(sid).mode == "default"
      refute_receive {:studio_chat_mode_adopted, _, _}, 200
    end
  end

  describe "agent_state heartbeat (charter D41h)" do
    setup %{sid: sid} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      prev = Application.get_env(:barkpark, :studio_chat_agent_heartbeat_ms)
      Application.put_env(:barkpark, :studio_chat_agent_heartbeat_ms, 40)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :studio_chat_agent_heartbeat_ms, prev),
          else: Application.delete_env(:barkpark, :studio_chat_agent_heartbeat_ms)
      end)

      %{sid: sid}
    end

    defp drain_heartbeats(sid) do
      receive do
        {:chat_heartbeat, ^sid, _} -> drain_heartbeats(sid)
      after
        0 -> :ok
      end
    end

    test "while working the tick bumps agent_state_at and broadcasts {:chat_heartbeat}",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      %{agent_state: "working", agent_state_at: at0} = StudioChat.get_session(sid)

      assert_receive {:chat_heartbeat, ^sid, %DateTime{}}, 1_000

      # the tick bumped ONLY the stamp — the state did not flip
      s = StudioChat.get_session(sid)
      assert s.agent_state == "working"
      assert DateTime.compare(s.agent_state_at, at0) == :gt
    end

    test "while blocked the heartbeat keeps beating (the sweeper must never reap a waiting ask)",
         %{sid: sid, recorder: recorder} do
      frame(
        recorder,
        {:claude_chat_permission,
         %{request_id: "hb-1", tool_name: "Write", input: %{}, title: nil, decision_reason: nil}}
      )

      assert StudioChat.get_session(sid).agent_state == "blocked"
      assert_receive {:chat_heartbeat, ^sid, %DateTime{}}, 1_000
    end

    test "a flip to idle cancels the heartbeat — no ticks at rest",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      frame(recorder, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

      # let any tick already in flight land, then demand silence
      Process.sleep(80)
      drain_heartbeats(sid)
      refute_receive {:chat_heartbeat, ^sid, _}, 150
    end
  end

  describe "workspace stamp on the activity broadcast (charter D43h)" do
    setup do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      :ok
    end

    test "publish_activity stamps owner_workspace_id as a MAP key; the stored map stays UNSTAMPED" do
      ws = Ecto.UUID.generate()
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"}, {:workspace, ws})

      {:ok, recorder} =
        Recorder.ensure(%{session_id: id, mode: "plan", resume: false, workspace_id: ws})

      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      # still a 3-tuple; the stamp rides the MAP (never a 4th element)
      assert_receive {:chat_activity, ^id,
                      %{state: :working, line: "thinking…", owner_workspace_id: ^ws}}

      # the SAME activity again is gated: the stored map is UNSTAMPED, so the
      # change-detect compare still collapses — a stamped store would
      # re-broadcast every identical activity forever
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      refute_receive {:chat_activity, ^id, _}, 100
    end

    test "a workspace-less session stamps owner_workspace_id: nil (fail-closed downstream)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      assert_receive {:chat_activity, ^sid, %{state: :working} = act}
      assert Map.fetch!(act, :owner_workspace_id) == nil
    end
  end

  # ── herd-s6 fixtures: a REAL registered host + execution lease ──────────────
  #
  # The report fence is a literal chat_execution_leases reuse (D79h), so these
  # tests enroll a real host and insert a real lease row — the corroborating
  # EXISTS predicate and the FOR-UPDATE fence validation both hit the actual
  # table, never a stub.
  defp reporter_host! do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Barkpark.Tenancy.create_workspace(%{slug: "s6-#{suffix}", name: "S6 #{suffix}"})

    {:ok, %{enrollment_token: token}} =
      Barkpark.ChatHosts.issue_enrollment(ws.id, %{name: "reporter"})

    {:ok, %{credential: credential}} = Barkpark.ChatHosts.enroll(token)
    {:ok, host} = Barkpark.ChatHosts.authenticate(credential)
    host
  end

  defp lease!(host, sid, opts \\ []) do
    {:ok, lease} =
      %Barkpark.ChatHosts.ExecutionLease{}
      |> Barkpark.ChatHosts.ExecutionLease.changeset(%{
        host_id: host.id,
        workspace_id: host.workspace_id,
        session_id: sid,
        provider: "claude",
        command_key: "ck-#{System.unique_integer([:positive])}",
        status: Keyword.get(opts, :status, "running"),
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
      })
      |> Repo.insert()

    lease
  end

  defp expire_lease!(lease) do
    {1, _} =
      Repo.update_all(
        from(l in Barkpark.ChatHosts.ExecutionLease, where: l.id == ^lease.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

    :ok
  end

  describe "external reporter fence — precedence + explicit hand-back (herd-s6, D79h)" do
    setup %{sid: sid} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      %{sid: sid, host: reporter_host!()}
    end

    # Precedence BOTH directions: → while the fence lives the reporter is SOLE
    # truth (derived flips touch NEITHER the store NOR the wire); ← on lease
    # expiry the recorder hands authority back explicitly. (Name kept short:
    # the OTP atom limit is 255 BYTES and closure atoms append '/1-fun-N-'.)
    test "precedence both ways: fenced reporter is sole truth on store + wire; expiry hands back",
         %{sid: sid, recorder: recorder, host: host} do
      frame(recorder, init_frame())
      assert agent_state(sid) == "working"
      assert_receive {:chat_activity, ^sid, %{state: :working}}

      lease = lease!(host, sid)

      assert {:ok, %{agent_state: "blocked", lease_id: lease_id}} =
               Barkpark.ChatHosts.report_state(host, sid, "blocked", lease.epoch)

      assert lease_id == lease.id
      # reported truth lands in the store AND speaks on the fleet-feeding topic
      assert agent_state(sid) == "blocked"
      assert_receive {:chat_reported_state, ^sid, %{agent_state: "blocked"}}

      # a derived idle transition (the result frame) arrives while fenced…
      frame(recorder, result_frame())
      # …and overwrites NEITHER barrel: not the column, not the wire
      assert agent_state(sid) == "blocked"
      refute_receive {:chat_activity, ^sid, %{state: :idle}}, 100

      # PRECEDENCE ←: the reporter dies — its lease expires (the 60s TTL
      # clock); the fence check finds no live lease and hands authority back:
      # the recorder re-asserts its CURRENT derived truth on both barrels.
      expire_lease!(lease)
      send(recorder, :reported_fence_check)
      :sys.get_state(recorder)

      assert agent_state(sid) == "idle"
      assert_receive {:chat_activity, ^sid, %{state: :idle}}
    end

    test "a still-live lease re-arms the fence check — no premature hand-back",
         %{sid: sid, recorder: recorder, host: host} do
      frame(recorder, init_frame())
      lease = lease!(host, sid)
      assert {:ok, _} = Barkpark.ChatHosts.report_state(host, sid, "blocked", lease.epoch)
      assert agent_state(sid) == "blocked"

      # the check fires while the host heartbeat still keeps the lease live
      send(recorder, :reported_fence_check)
      :sys.get_state(recorder)

      # still suspended: a derived idle flip stays off both barrels
      frame(recorder, result_frame())
      assert agent_state(sid) == "blocked"
      refute_receive {:chat_activity, ^sid, %{state: :idle}}, 100
    end

    test "the 60s heartbeat is fence-aware: NO freshness stamp while the fence holds (the composed freeze hazard)",
         %{sid: sid, recorder: recorder, host: host} do
      frame(recorder, init_frame())
      assert agent_state(sid) == "working"

      lease = lease!(host, sid)
      assert {:ok, _} = Barkpark.ChatHosts.report_state(host, sid, "working", lease.epoch)
      %{agent_state_at: at0} = StudioChat.get_session(sid)

      # the recorder's cache says "working", so WITHOUT the fence gate this
      # tick would touch agent_state_at and keep a dead reporter's row
      # eternally fresh — sweep-proof. Fence-aware: no touch.
      send(recorder, :agent_state_heartbeat)
      :sys.get_state(recorder)
      %{agent_state_at: at1} = StudioChat.get_session(sid)
      assert DateTime.compare(at0, at1) == :eq

      # non-vacuous: after hand-back the SAME tick touches again
      expire_lease!(lease)
      send(recorder, :reported_fence_check)
      :sys.get_state(recorder)
      %{agent_state_at: at2} = StudioChat.get_session(sid)

      send(recorder, :agent_state_heartbeat)
      :sys.get_state(recorder)
      %{agent_state_at: at3} = StudioChat.get_session(sid)
      assert DateTime.compare(at3, at2) == :gt
    end
  end

  describe "codex derivation completeness — the SHARED path, never a second mapper (herd-s6, D78h)" do
    defp codex_ev(sid, kind, overrides \\ []) do
      struct!(%Event{kind: kind, provider: "codex", session_id: sid}, overrides)
    end

    defp fresh_codex_session! do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
      {:ok, rec} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
      {id, rec}
    end

    defp codex_ask_ev(sid, approval_id) do
      codex_ev(sid, :approval_requested,
        approval_id: approval_id,
        native: %{"method" => "item/commandExecution/requestApproval", "params" => %{}}
      )
    end

    test "turn/completed lands idle for terminal_state :completed AND :interrupted",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:studio_chat_runtime_event, codex_ev(sid, :turn_started)})
      assert agent_state(sid) == "working"

      frame(
        recorder,
        {:studio_chat_runtime_event, codex_ev(sid, :turn_completed, terminal_state: :completed)}
      )

      assert agent_state(sid) == "idle"

      frame(recorder, {:studio_chat_runtime_event, codex_ev(sid, :turn_started)})
      assert agent_state(sid) == "working"

      frame(
        recorder,
        {:studio_chat_runtime_event, codex_ev(sid, :turn_completed, terminal_state: :interrupted)}
      )

      assert agent_state(sid) == "idle"
    end

    test "a FAILED codex turn lands idle — the failed→idle row is DELIBERATE (D78h), not an accident",
         %{sid: sid, recorder: recorder} do
      frame(recorder, {:studio_chat_runtime_event, codex_ev(sid, :turn_started)})
      assert agent_state(sid) == "working"

      # codex "turn/completed" with turn.status=failed normalizes to
      # kind :turn_completed / terminal_state :failed (Protocol.normalize/2) —
      # the turn SETTLED, nothing is running and nothing needs the human, so
      # the honest herd state is idle, never unknown/blocked.
      frame(
        recorder,
        {:studio_chat_runtime_event, codex_ev(sid, :turn_completed, terminal_state: :failed)}
      )

      assert agent_state(sid) == "idle"
    end

    test "unknown from :process_failed with a BLOCKED prior and from :protocol_error with a working prior",
         %{sid: sid, recorder: recorder} do
      # blocked prior: a mid-ask process death is possibly-wedged → unknown
      frame(recorder, {:studio_chat_runtime_event, codex_ev(sid, :turn_started)})
      frame(recorder, {:studio_chat_runtime_event, codex_ask_ev(sid, "cdx-pf")})
      assert agent_state(sid) == "blocked"

      frame(recorder, {:studio_chat_runtime_event, codex_ev(sid, :process_failed)})
      assert agent_state(sid) == "unknown"

      # working prior on a FRESH session: protocol death → unknown
      {sid2, rec2} = fresh_codex_session!()
      frame(rec2, {:studio_chat_runtime_event, codex_ev(sid2, :turn_started)})
      assert StudioChat.get_session(sid2).agent_state == "working"

      frame(rec2, {:studio_chat_runtime_event, codex_ev(sid2, :protocol_error)})
      assert StudioChat.get_session(sid2).agent_state == "unknown"
    end

    test "never-blocked sweep: NO normalized kind except :approval_requested can produce blocked" do
      # Every kind the codex Protocol + host normalizer can emit. Each runs
      # against a FRESH session so no prior state can mask a stray blocked.
      kinds = [
        :session_started,
        :turn_started,
        :text_delta,
        :thinking_delta,
        :tool_delta,
        :item_started,
        :item_completed,
        :usage,
        :turn_completed,
        :control_completed,
        :error,
        :process_failed,
        :protocol_error,
        :provider_event,
        :runtime_acknowledged
      ]

      for kind <- kinds do
        {sid, rec} = fresh_codex_session!()

        frame(
          rec,
          {:studio_chat_runtime_event,
           codex_ev(sid, kind, native: %{"params" => %{"item" => %{}}})}
        )

        assert StudioChat.get_session(sid).agent_state != "blocked",
               "normalized kind #{inspect(kind)} must NEVER produce blocked"

        # release the managed-runtime admission slot before the next kind —
        # 15 concurrent recorders would trip the capacity cap, not the sweep
        :ok = DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, rec)
      end

      # non-vacuous control: the ONE excepted kind DOES block — the sweep's
      # harness is provably able to observe a blocked write.
      {sid, rec} = fresh_codex_session!()
      frame(rec, {:studio_chat_runtime_event, codex_ask_ev(sid, "nb-ctl")})
      assert StudioChat.get_session(sid).agent_state == "blocked"
    end
  end

  describe "AgentStateSweeper (charter D42h)" do
    defp seed_agent_state(state, at) do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})

      {1, _} =
        Repo.update_all(
          from(s in Session, where: s.id == ^id),
          set: [agent_state: state, agent_state_at: at]
        )

      id
    end

    defp long_ago, do: DateTime.add(DateTime.utc_now(), -300, :second)

    test "stale working/blocked rows (old OR NULL stamp) sweep to unknown" do
      stale_working = seed_agent_state("working", long_ago())
      stale_blocked = seed_agent_state("blocked", long_ago())
      null_working = seed_agent_state("working", nil)

      AgentStateSweeper.sweep()

      assert StudioChat.get_session(stale_working).agent_state == "unknown"
      assert StudioChat.get_session(stale_blocked).agent_state == "unknown"
      assert StudioChat.get_session(null_working).agent_state == "unknown"
    end

    test "a FRESH (≤150s heartbeated) working or blocked row is NEVER swept" do
      fresh_working = seed_agent_state("working", DateTime.utc_now())
      fresh_blocked = seed_agent_state("blocked", DateTime.utc_now())

      AgentStateSweeper.sweep()

      assert StudioChat.get_session(fresh_working).agent_state == "working"
      assert StudioChat.get_session(fresh_blocked).agent_state == "blocked"
    end

    test "staleness-SCOPED, never blanket: idle/unknown rows are untouched regardless of age" do
      old_idle = seed_agent_state("idle", long_ago())
      old_unknown = seed_agent_state("unknown", nil)

      assert AgentStateSweeper.sweep() == 0

      assert StudioChat.get_session(old_idle).agent_state == "idle"
      assert StudioChat.get_session(old_unknown).agent_state == "unknown"
    end

    test "init sweeps SYNCHRONOUSLY — the boot sweep beats the first request" do
      stale = seed_agent_state("working", nil)

      start_supervised!(
        {AgentStateSweeper, name: :"#{__MODULE__}.BootSweeper"},
        id: :boot_sweeper_test
      )

      # start_supervised! returns only after init/1 — the row is already swept
      assert StudioChat.get_session(stale).agent_state == "unknown"
    end

    test "fence-aware: a stale working/blocked row under a LIVE report fence is never swept (herd-s6, D79h)" do
      stale_working = seed_agent_state("working", long_ago())
      stale_blocked = seed_agent_state("blocked", nil)
      host = reporter_host!()
      _lease_w = lease!(host, stale_working)
      _lease_b = lease!(host, stale_blocked, status: "leased")

      assert AgentStateSweeper.sweep() == 0
      assert StudioChat.get_session(stale_working).agent_state == "working"
      assert StudioChat.get_session(stale_blocked).agent_state == "blocked"
    end

    test "a DEAD reporter's value is never sweep-proof: an expired/revoked lease stops shielding (herd-s6, D79h)" do
      # the composed freeze hazard, closed: the reporter died, its lease
      # expired within the 60s TTL — the row must age into the sweep window
      # like any other working/blocked row.
      expired = seed_agent_state("blocked", long_ago())
      revoked = seed_agent_state("working", long_ago())
      host = reporter_host!()

      _expired_lease =
        lease!(host, expired, expires_at: DateTime.add(DateTime.utc_now(), -5, :second))

      revoked_lease = lease!(host, revoked)

      {1, _} =
        Repo.update_all(
          from(l in Barkpark.ChatHosts.ExecutionLease, where: l.id == ^revoked_lease.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert AgentStateSweeper.sweep() == 2
      assert StudioChat.get_session(expired).agent_state == "unknown"
      assert StudioChat.get_session(revoked).agent_state == "unknown"
    end
  end

  # ── the durable accumulator's per-turn byte cap (charter D169) ──────────────
  #
  # `runtime_text` (the codex lane's TURN-scoped durable accumulator) persists
  # verbatim as `source_markdown` at BOTH persist sites — turn_completed and the
  # terminal-error clause. D64's 262_144 bound covers only the DISPLAY tail
  # (StreamSegments); the PERSIST path had no twin, so a runaway turn could write
  # unbounded bytes into one chat_messages row. These tests pin the config-
  # overridable byte cap at both sites, truncate-with-marker (NEVER turn-abort —
  # W22/D131), and prove the guard is load-bearing by mutation (disable it → red).
  describe "runtime_text per-turn byte cap (charter D169)" do
    @cap_bytes 256

    setup do
      current = Application.get_env(:barkpark, :claude_chat, [])

      Application.put_env(
        :barkpark,
        :claude_chat,
        Keyword.put(current, :max_runtime_text_bytes, @cap_bytes)
      )

      on_exit(fn -> Application.put_env(:barkpark, :claude_chat, current) end)
      :ok
    end

    defp text_delta(sid, payload) do
      {:studio_chat_runtime_event,
       %Event{
         kind: :text_delta,
         provider: "codex",
         session_id: sid,
         native: %{"params" => %{"delta" => payload}}
       }}
    end

    defp runtime_kind(sid, kind),
      do: {:studio_chat_runtime_event, %Event{kind: kind, provider: "codex", session_id: sid}}

    defp persisted_assistant(sid),
      do: StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "assistant"))

    test "turn_completed persists TRUNCATED-with-marker, never beyond the cap (:1126 site)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, runtime_kind(sid, :turn_started))
      # one turn's worth of deltas, far past the 256-byte cap
      frame(recorder, text_delta(sid, String.duplicate("a", 4096)))
      frame(recorder, runtime_kind(sid, :turn_completed))

      row = persisted_assistant(sid)
      assert row, "turn_completed must persist the codex assistant row"
      # THE BOUND: the durable byte size never exceeds the configured cap…
      assert byte_size(row.source_markdown) <= @cap_bytes
      # …the turn still SETTLED (it truncated, it did not abort)…
      assert String.ends_with?(row.source_markdown, "truncated at the persist byte cap …]")
      # …and the text really was clipped (non-vacuous: 4096 bytes went in).
      assert byte_size(row.source_markdown) < 4096
    end

    test "the terminal-error clause persists TRUNCATED text too (:1145 site)",
         %{sid: sid, recorder: recorder} do
      frame(recorder, runtime_kind(sid, :turn_started))
      frame(recorder, text_delta(sid, String.duplicate("b", 4096)))
      # a mid-turn death: the terminal-error clause is the SECOND persist site
      frame(recorder, runtime_kind(sid, :error))

      row = persisted_assistant(sid)
      assert row, "the terminal-error clause must persist the partial turn"
      assert byte_size(row.source_markdown) <= @cap_bytes
      assert String.ends_with?(row.source_markdown, "truncated at the persist byte cap …]")
    end

    test "a turn UNDER the cap persists verbatim — no marker, no clip",
         %{sid: sid, recorder: recorder} do
      frame(recorder, runtime_kind(sid, :turn_started))
      frame(recorder, text_delta(sid, "a short honest answer"))
      frame(recorder, runtime_kind(sid, :turn_completed))

      row = persisted_assistant(sid)
      assert row.source_markdown == "a short honest answer"
      refute String.contains?(row.source_markdown, "truncated at the persist byte cap")
    end

    test "raising the cap lets the full turn persist (config is truly overridable)",
         %{sid: sid, recorder: recorder} do
      current = Application.get_env(:barkpark, :claude_chat, [])

      Application.put_env(
        :barkpark,
        :claude_chat,
        Keyword.put(current, :max_runtime_text_bytes, 100_000)
      )

      frame(recorder, runtime_kind(sid, :turn_started))
      frame(recorder, text_delta(sid, String.duplicate("c", 4096)))
      frame(recorder, runtime_kind(sid, :turn_completed))

      row = persisted_assistant(sid)
      # under the raised cap the whole 4096 bytes survive, no marker
      assert byte_size(row.source_markdown) == 4096
      refute String.contains?(row.source_markdown, "truncated at the persist byte cap")
    end

    test "the Message changeset carries a grapheme backstop on source_markdown" do
      # The byte cap is the real bound; this is the second fence. Prove it exists
      # and reds a pathological over-long row (independent of the recorder path).
      over = String.duplicate("x", 1_048_577)

      cs =
        Barkpark.StudioChat.Message.changeset(%Barkpark.StudioChat.Message{}, %{
          session_id: Ecto.UUID.generate(),
          seq: 1,
          role: "assistant",
          source_markdown: over
        })

      refute cs.valid?
      assert %{source_markdown: [_ | _]} = Ecto.Changeset.traverse_errors(cs, & &1)
    end
  end

  # ── live ledger transitions re-broadcast for bp chat (tlv) ─────────────────
  #
  # The Recorder rides the SAME `documents:production` ledger stream Studio's
  # chat_live does, folds it through the SAME pure rule, and re-broadcasts the
  # scoped result on `topic/1` — the per-session topic the SSE forwarder (and
  # only the SSE forwarder) subscribes to. That second broadcast is what gives
  # `bp chat` a live transition without a second bus.
  describe "task transitions re-broadcast on the session topic (tlv)" do
    # A ledger broadcast in the shape Content.Broadcast.broadcast_document_mutation/3
    # emits — the lean subset the fold reads.
    defp task_doc_changed(doc_id, title, content, opts) do
      {:document_changed,
       %{
         type: "task",
         doc_id: doc_id,
         rev: Keyword.get(opts, :rev, "rev-1"),
         mutation: Keyword.fetch!(opts, :mutation),
         event_id: Keyword.fetch!(opts, :event_id),
         doc: %{
           doc_id: doc_id,
           title: title,
           status: "published",
           content: content,
           updated_at: nil
         }
       }}
    end

    test "our worker's claim re-broadcasts a compact transition", %{
      sid: sid,
      recorder: recorder
    } do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      worker = Barkpark.StudioChat.Runtime.worker_id("claude", sid)

      frame(
        recorder,
        task_doc_changed(
          "task-rec-1",
          "Mend the fence",
          %{"lifecycle_status" => "in_progress", "claim" => %{"worker" => worker}},
          mutation: "task.claimed",
          event_id: "ev-rec-1"
        )
      )

      assert_receive {:chat_task_transition, ^sid, summary}
      assert summary.event_id == "ev-rec-1"
      assert summary.task_id == "task-rec-1"
      assert summary.status == "in_progress"
      assert summary.verb == "claimed"
      assert summary.label == "Mend the fence → in_progress (claimed)"
    end

    test "a replayed event re-broadcasts ONCE", %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      worker = Barkpark.StudioChat.Runtime.worker_id("claude", sid)

      msg =
        task_doc_changed(
          "task-rec-2",
          "Dig the trench",
          %{"lifecycle_status" => "in_progress", "claim" => %{"worker" => worker}},
          mutation: "task.claimed",
          event_id: "ev-rec-2"
        )

      frame(recorder, msg)
      frame(recorder, msg)

      assert_receive {:chat_task_transition, ^sid, %{event_id: "ev-rec-2"}}
      refute_receive {:chat_task_transition, _, %{event_id: "ev-rec-2"}}, 100
    end

    test "another worker's task never re-broadcasts", %{sid: sid, recorder: recorder} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      frame(
        recorder,
        task_doc_changed(
          "task-rec-3",
          "Not ours",
          %{
            "lifecycle_status" => "in_progress",
            "claim" => %{"worker" => "claude-chat-deadbeef"}
          },
          mutation: "task.claimed",
          event_id: "ev-rec-3"
        )
      )

      refute_receive {:chat_task_transition, _, _}, 100
    end

    test "nothing is persisted — the transition is live-only chrome", %{
      sid: sid,
      recorder: recorder
    } do
      before = length(StudioChat.list_messages(sid))
      worker = Barkpark.StudioChat.Runtime.worker_id("claude", sid)

      frame(
        recorder,
        task_doc_changed(
          "task-rec-4",
          "Leave no row",
          %{"lifecycle_status" => "done", "claim" => %{"worker" => worker}},
          mutation: "task.closed",
          event_id: "ev-rec-4"
        )
      )

      assert length(StudioChat.list_messages(sid)) == before
    end
  end
end
