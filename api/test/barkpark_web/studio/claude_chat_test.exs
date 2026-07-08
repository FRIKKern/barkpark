defmodule BarkparkWeb.Studio.ClaudeChatTest do
  @moduledoc """
  Gate + subprocess behavior of the Studio Claude chat seam. No real `claude`
  anywhere: the command is overridden with `cat` (echo server — a written
  NDJSON user message rides straight back through the real Port + parse
  path) and tiny `sh -c` scripts (canned init events, exit statuses).
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.Studio.ClaudeChat

  defp put_chat_config(config) do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, config)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  describe "enabled?/0 (fail-closed gate)" do
    test "off when the flag is explicitly disabled" do
      put_chat_config(enabled: false, command: {"cat", []})
      refute ClaudeChat.enabled?()
    end

    test "on with an available command and the default flag" do
      put_chat_config(command: {"cat", []})
      assert ClaudeChat.enabled?()
    end

    test "hard-refuses public-demo hosts regardless of the flag" do
      put_chat_config(enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, true)
      refute ClaudeChat.enabled?()
    end

    test "off when the binary is not installed" do
      put_chat_config(enabled: true, command: {"definitely-not-a-real-binary-bp", []})
      refute ClaudeChat.enabled?()
    end

    test "start_session refuses when disabled" do
      put_chat_config(enabled: false, command: {"cat", []})
      assert {:error, :disabled} = ClaudeChat.start_session(%{sink: self()})
    end
  end

  describe "parse_chunk/2 (NDJSON line assembly)" do
    test "decodes complete lines and keeps the partial tail" do
      chunk = ~s({"type":"a"}\n{"type":"b"}\n{"ty)
      assert {[%{"type" => "a"}, %{"type" => "b"}], ~s({"ty)} = ClaudeChat.parse_chunk("", chunk)
    end

    test "joins a split line across chunks" do
      {[], rest} = ClaudeChat.parse_chunk("", ~s({"type":"sys))
      assert {[%{"type" => "system"}], ""} = ClaudeChat.parse_chunk(rest, ~s(tem"}\n))
    end

    test "drops non-JSON lines without crashing" do
      chunk = "not json\n{\"ok\":true}\n"
      assert {[%{"ok" => true}], ""} = ClaudeChat.parse_chunk("", chunk)
    end

    test "ignores blank lines" do
      assert {[%{"a" => 1}], ""} = ClaudeChat.parse_chunk("", "\n{\"a\":1}\n\n")
    end
  end

  describe "session subprocess" do
    test "round-trips a user message through a real Port (cat echo)" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ClaudeChat.send_message(session, "hello there")

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "user",
                        "message" => %{
                          "content" => [%{"type" => "text", "text" => "hello there"}]
                        }
                      }},
                     2_000

      ClaudeChat.close(session)
    end

    test "delivers canned events and the exit status" do
      script = ~s(printf '%s\\n' '{"type":"system","subtype":"init","model":"test-model"}')
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event,
                      %{"type" => "system", "subtype" => "init", "model" => "test-model"}},
                     2_000

      assert_receive {:claude_chat_exit, 0}, 2_000
    end

    test "reports a non-zero exit status" do
      put_chat_config(command: {"sh", ["-c", "exit 3"]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_exit, 3}, 2_000
    end

    test "session dies with its sink (no leaked subprocess owner)" do
      put_chat_config(command: {"cat", []})

      test_pid = self()

      sink =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session} = ClaudeChat.start_session(%{sink: sink})
      ref = Process.monitor(session)
      send(test_pid, :ready)
      send(sink, :stop)

      assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2_000
    end
  end
end
