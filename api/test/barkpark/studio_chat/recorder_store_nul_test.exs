defmodule Barkpark.StudioChat.RecorderStoreNulTest do
  @moduledoc """
  The Recorder's store calls other than `persist/3` (task-c9699c90987b5128).

  Postgres refuses U+0000 in jsonb (22P05) and in a text parameter (22021),
  and the store raises, so a frame holding U+0000 crashed the Recorder at
  `attach_tool_result`, `update_tool_input`, `merge_tool_metadata` or
  `set_rail_snapshot`. Today every frame passes a decoder that replaces it
  first (the managed CLI's sink, the host event intake), so this guards a new
  frame source. The frames here go straight to the Recorder, past any
  decoder.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  @nul <<0>>
  @fffd "�"

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

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
    %{sid: id, recorder: recorder}
  end

  test "a tool result holding U+0000 is attached with U+FFFD", %{sid: sid, recorder: recorder} do
    frame(recorder, tool_use("toolu_r", "Bash", %{"command" => "ls"}))
    frame(recorder, tool_result("toolu_r", "out" <> @nul))

    assert Process.alive?(recorder)
    assert row(sid, "toolu_r").metadata["output"] == "out" <> @fffd
  end

  test "a TodoWrite update holding U+0000 is stored with U+FFFD", %{sid: sid, recorder: recorder} do
    frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
    frame(recorder, tool_use("toolu_t1", "TodoWrite", todos("first")))
    frame(recorder, tool_use("toolu_t2", "TodoWrite", todos("second" <> @nul)))

    assert Process.alive?(recorder)

    assert [%{"content" => "second" <> @fffd}] =
             row(sid, "toolu_t1").metadata["input"]["todos"]
  end

  test "a sub-agent's progress line and ids holding U+0000 are stamped with U+FFFD",
       %{sid: sid, recorder: recorder} do
    spawn_id = "toolu_s" <> @nul
    frame(recorder, tool_use(spawn_id, "Task", %{"description" => "Count", "prompt" => "go"}))
    frame(recorder, system("task_started", %{"task_id" => "t", "tool_use_id" => spawn_id}))

    frame(
      recorder,
      system("task_progress", %{
        "task_id" => "t",
        "tool_use_id" => spawn_id,
        "description" => "Running" <> @nul
      })
    )

    assert Process.alive?(recorder)
    row = row(sid, "toolu_s" <> @fffd)
    assert row.metadata["task_status"] == "running"
    assert row.metadata["task_progress"] == "Running" <> @fffd
  end

  test "an agents-rail row holding U+0000 is stored with U+FFFD", %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      system("background_tasks_changed", %{
        "tasks" => [
          %{"task_id" => "a", "task_type" => "local_workflow", "description" => "Build" <> @nul}
        ]
      })
    )

    assert Process.alive?(recorder)
    rail = StudioChat.get_session(sid).rail_snapshot
    assert rail["a"]["row"]["description"] == "Build" <> @fffd
  end

  test "store calls without U+0000 keep their bytes", %{sid: sid, recorder: recorder} do
    text = "plain, emoji 🐕‍🦺 שלום, tab\there, " <> <<1>> <> ", the literal \\u0000"

    frame(recorder, tool_use("toolu_p", "Bash", %{"command" => "ls"}))
    frame(recorder, tool_result("toolu_p", text))

    frame(
      recorder,
      system("background_tasks_changed", %{
        "tasks" => [%{"task_id" => "p", "task_type" => "local_workflow", "description" => text}]
      })
    )

    assert row(sid, "toolu_p").metadata["output"] == text
    assert StudioChat.get_session(sid).rail_snapshot["p"]["row"]["description"] == text
  end

  defp tool_use(id, name, input) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "message" => %{
         "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
       }
     }}
  end

  defp tool_result(id, text) do
    {:claude_chat_event,
     %{
       "type" => "user",
       "message" => %{
         "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => text}]
       }
     }}
  end

  defp todos(content), do: %{"todos" => [%{"content" => content, "status" => "pending"}]}

  defp system(subtype, fields),
    do: {:claude_chat_event, Map.merge(%{"type" => "system", "subtype" => subtype}, fields)}

  defp row(sid, tool_use_id),
    do:
      StudioChat.list_messages(sid, :global)
      |> Enum.find(&(&1.metadata["tool_use_id"] == tool_use_id))

  defp frame(recorder, msg) do
    send(recorder, msg)
    :sys.get_state(recorder)
    :ok
  end
end
