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

  What the managed CLI sends to its sink, and every row the Recorder stores,
  now get U+FFFD in place of U+0000, through the same `ChatHosts.EventText`
  the host event intake uses. What goes back to the CLI does not: a plain
  allow echoes the tool input byte for byte (review of #26731), so the bytes a
  tool writes never depend on the permission mode.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  @nul <<0>>
  @fffd "\uFFFD"

  # A managed Codex runtime whose app-server answered thread/start with a thread
  # id holding U+0000 (task-cde71b04cdc73529).
  defmodule NulThreadCodex do
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(_opts) do
      {:ok,
       %{
         runtime: spawn(fn -> receive do: (:stop -> :ok) end),
         provider_session_id: "thr" <> <<0>> <> "1"
       }}
    end

    def resume(opts), do: start(opts)
    def send_turn(_runtime, _content), do: :ok
    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, "interrupt"}
    def answer_approval(_runtime, _approval_id, _decision), do: :ok
    def readiness(_opts), do: %{ready?: true}
    def capabilities, do: %{modes: [], models: [], efforts: []}
    def close(%{runtime: pid}), do: send(pid, :stop) && :ok
  end

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

  test "the managed CLI's sink gets U+FFFD, and a plain allow echoes the CLI's own bytes" do
    out = Path.join(System.tmp_dir!(), "nul-echo-#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm(out) end)

    reply = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"a\\u0000b"}]}})

    ask =
      ~s({"type":"control_request","request_id":"req-n","request":{"subtype":"can_use_tool",) <>
        ~s("tool_name":"Write","input":{"file_path":"/tmp/x","content":"a\\u0000b"}}})

    script = ~s(printf '%s\\n' '#{reply}' '#{ask}'; cat > #{out})
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"sh", ["-c", script]})

    {:ok, session} = ClaudeChat.start_session(%{sink: self()})

    assert_receive {:claude_chat_event, %{"type" => "assistant"} = event}, 5_000
    assert [%{"text" => "a" <> @fffd <> "b"}] = event["message"]["content"]

    assert_receive {:claude_chat_permission, %{request_id: "req-n", input: input}}, 5_000
    assert input["content"] == "a" <> @fffd <> "b"

    ClaudeChat.respond_permission(session, "req-n", :allow)

    line =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(100)

        File.exists?(out) &&
          out |> File.read!() |> String.split("\n") |> Enum.find(&(&1 =~ "req-n"))
      end)

    assert line, "no control_response reached the CLI"
    sent = Jason.decode!(line)
    assert get_in(sent, ["response", "response", "updatedInput", "content"]) == "a" <> @nul <> "b"
    ClaudeChat.close(session)
  end

  # task-cde71b04cdc73529: today Claude request ids are UUIDs, so this is the
  # first id the sink and the CLI would disagree on. The sink gets U+FFFD; the
  # answer names that id; the CLI gets back its own id and its own input.
  test "an ask whose request_id holds U+0000 is answered by a plain allow with the CLI's own id" do
    out = Path.join(System.tmp_dir!(), "nul-rid-#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm(out) end)

    ask =
      ~s({"type":"control_request","request_id":"r\\u00001","request":{"subtype":"can_use_tool",) <>
        ~s("tool_name":"Write","input":{"file_path":"/tmp/x","content":"ok"}}})

    script = ~s(printf '%s\\n' '#{ask}'; cat > #{out})
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"sh", ["-c", script]})

    {:ok, session} = ClaudeChat.start_session(%{sink: self()})
    sink_id = "r" <> @fffd <> "1"
    assert_receive {:claude_chat_permission, %{request_id: ^sink_id}}, 5_000

    ClaudeChat.respond_permission(session, sink_id, :allow)

    line =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(100)

        File.exists?(out) &&
          out |> File.read!() |> String.split("\n") |> Enum.find(&(&1 =~ "control_response"))
      end)

    assert line, "no control_response reached the CLI"
    sent = Jason.decode!(line)
    assert get_in(sent, ["response", "request_id"]) == "r" <> @nul <> "1"

    assert get_in(sent, ["response", "response", "updatedInput"]) ==
             %{"file_path" => "/tmp/x", "content" => "ok"}

    ClaudeChat.close(session)
  end

  test "a Codex thread id holding U+0000 is stored with U+FFFD and the Recorder stays up" do
    prev = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{codex: NulThreadCodex})

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, prev),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: ClaudeChat.cwd(), mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: id, provider: "codex", mode: "plan"})
    :sys.get_state(recorder)

    assert Process.alive?(recorder)
    assert StudioChat.get_session(id).provider_session_id == "thr" <> @fffd <> "1"
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
