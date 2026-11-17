defmodule Barkpark.StudioChat.RecorderNulTextTest do
  @moduledoc """
  Managed-session model output holding U+0000 (task-75c44878c20cec3f).

  The named failure mode: on a managed session (the CLI runs over a Port here,
  not on a registered host) model output never passes
  `ChatHosts.accept_event/2`, so it kept its U+0000. Since #26702
  `StudioChat.append_message/2` answers `{:error, :nul_character}` for it, and
  the Recorder only logs that: the reply row was lost. When the lost row was an
  AskUserQuestion ask, `POST /answer` answered 404 (no pending question), so
  bp and TUI clients could not answer it.

  The managed CLI's decoded lines and every row the Recorder stores now get
  U+FFFD in place of U+0000, through the same `ChatHosts.EventText` the host
  event intake uses.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  @nul <<0>>
  @fffd "\uFFFD"

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

    admin = "rec-nul-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "rec-nul-admin", "production", ["read", "write", "admin"])

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: ClaudeChat.cwd(), mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
    %{sid: id, recorder: recorder, admin: admin}
  end

  test "an assistant frame whose text holds U+0000 is stored with U+FFFD, tool row included",
       %{sid: sid, recorder: recorder} do
    frame(
      recorder,
      {:claude_chat_event,
       %{
         "type" => "assistant",
         "message" => %{
           "content" => [
             %{"type" => "text", "text" => "a" <> @nul <> "b"},
             %{
               "type" => "tool_use",
               "name" => "Bash",
               "input" => %{"command" => "printf '" <> @nul <> "'"}
             }
           ]
         }
       }}
    )

    rows = StudioChat.list_messages(sid, :global)
    assert [reply] = Enum.filter(rows, &(&1.role == "assistant"))
    assert reply.source_markdown == "a" <> @fffd <> "b"

    assert [tool] = Enum.filter(rows, &(&1.role == "tool"))
    refute Jason.encode!(%{text: tool.source_markdown, metadata: tool.metadata}) =~ "\\u0000"
  end

  test "an AskUserQuestion ask holding U+0000 is stored, and HTTP answer takes it",
       %{sid: sid, recorder: recorder, admin: admin} do
    question = "Pick" <> @nul <> "one"

    frame(
      recorder,
      {:claude_chat_permission,
       %{
         request_id: "q-nul",
         tool_name: "AskUserQuestion",
         input: %{"questions" => [%{"question" => question, "options" => [%{"label" => "Cat"}]}]},
         title: nil,
         decision_reason: nil
       }}
    )

    assert [row] = StudioChat.list_messages(sid, :global) |> Enum.filter(&(&1.role == "question"))
    stored = "Pick" <> @fffd <> "one"
    assert [%{"question" => ^stored}] = row.metadata["input"]["questions"]

    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{admin}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/chat/sessions/#{sid}/answer",
        Jason.encode!(%{request_id: "q-nul", answers: %{stored => "Cat"}})
      )

    assert conn.status == 204, "answer answered #{conn.status}: #{conn.resp_body}"
  end

  test "the managed CLI's decoded line carries U+FFFD in place of U+0000" do
    line = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"a\\u0000b"}]}}\n)

    assert {[event], ""} = ClaudeChat.parse_chunk("", line)
    assert [%{"text" => text}] = event["message"]["content"]
    assert text == "a" <> @fffd <> "b"
  end

  test "output a managed CLI sends today is stored exactly as sent", %{
    sid: sid,
    recorder: recorder
  } do
    texts = [
      "plain",
      "emoji 🐕‍🦺 שלום",
      "tab\there\nline",
      <<1>>,
      <<0x7F>>,
      @fffd,
      "the literal \\u0000"
    ]

    for text <- texts do
      frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => text}]}
         }}
      )
    end

    stored = StudioChat.list_messages(sid, :global) |> Enum.filter(&(&1.role == "assistant"))
    assert Enum.map(stored, & &1.source_markdown) == texts

    line = ~s({"type":"assistant","note":"the literal \\\\u0000 and \\u0001"}\n)
    assert {[event], ""} = ClaudeChat.parse_chunk("", line)
    assert event["note"] == "the literal \\u0000 and " <> <<1>>
  end

  defp frame(recorder, msg) do
    send(recorder, msg)
    :sys.get_state(recorder)
    :ok
  end
end
