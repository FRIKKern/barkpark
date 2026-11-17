defmodule Barkpark.StudioChat.RecorderFlagCutTest do
  @moduledoc """
  task-fb5274e13f678d29: the per-turn byte cap on the durable accumulator
  (charter D169) backs off to a grapheme boundary. Before, it backed off to a
  codepoint, so a cap landing inside a flag stored one regional indicator (a
  boxed letter) in front of the truncation marker.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Event

  @cap_bytes 256
  # A copy of the Recorder's marker; the test fails loudly if it drifts.
  @marker "\n\n[… turn output truncated at the persist byte cap …]"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      command: {"cat", []},
      max_runtime_text_bytes: @cap_bytes
    )

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

  test "a cap that lands between a flag's two indicators stores no lone indicator",
       %{sid: sid, recorder: recorder} do
    keep = @cap_bytes - byte_size(@marker)
    # The cut falls 4 bytes into the 8-byte flag.
    text = String.duplicate("a", keep - 4) <> "🇳🇴" <> String.duplicate("b", 100)

    frame(recorder, runtime(sid, :turn_started))
    frame(recorder, %{runtime(sid, :text_delta) | native: %{"params" => %{"delta" => text}}})
    frame(recorder, runtime(sid, :turn_completed))

    row = StudioChat.list_messages(sid, :global) |> Enum.find(&(&1.role == "assistant"))
    assert row, "turn_completed must persist the codex assistant row"
    assert String.ends_with?(row.source_markdown, @marker)

    assert String.replace_suffix(row.source_markdown, @marker, "") ==
             String.duplicate("a", keep - 4)
  end

  defp runtime(sid, kind),
    do: %Event{kind: kind, provider: "codex", session_id: sid}

  defp frame(recorder, %Event{} = event) do
    send(recorder, {:studio_chat_runtime_event, event})
    :sys.get_state(recorder)
    :ok
  end
end
