defmodule Barkpark.StudioChat.ProviderPortEpipeTest do
  @moduledoc """
  The race behind task-9656eadf40e489f1 (ClaudeChatCloudSessionTest: the
  `bp_sandbox` binding never persisted) and task-77e397fbbc1e503e
  (ClaudeChatTurnHandoffTest: `{:claude_chat_exit, :crashed, nil}` instead of
  `{:held_in_terminate, _}`), driven deterministically.

  The Recorder casts `initialize` to the provider Session right after spawn.
  The test stubs print their frames and exit WITHOUT reading stdin. Under CI
  load the Session can handle that cast after the child has stopped reading but
  before the port has closed: the write fails with EPIPE and the port exits
  `:epipe`. The Session did not trap exits, so that signal KILLED it — the
  frames still queued in its mailbox (the `bp_sandbox` binding, the `result`)
  were never dispatched, the sink saw only `:DOWN` (the Recorder broadcasts
  `:crashed`), and `terminate/2` (stderr rm, MCP token revoke) never ran.

  The ordering is HELD here, not slept into: the Session is suspended, the
  `initialize` cast is queued FIRST, the stub (stdin already closed) is then
  released to print, and the test waits until the frames are actually sitting
  in the Session's mailbox before resuming it. The write is the first thing the
  resumed Session does, and it meets a closed pipe every time.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat.Provider.Claude, as: ClaudeChat

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    # Chat is refused on a public-demo host; the test env turns that demo on.
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)
    end)

    dir =
      Path.join(System.tmp_dir!(), "claude_chat_epipe_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Closes its stdin at once, waits for `go`, prints two frames, then lingers so
  # the port is still open (child alive, stdin closed) when the Session writes.
  defp stub(dir, linger \\ 2) do
    path = Path.join(dir, "stub.sh")
    go = Path.join(dir, "go")

    File.write!(path, """
    #!/bin/sh
    exec 0<&-
    while [ ! -f '#{go}' ]; do sleep 0.01; done
    printf '%s\\n' '{"type":"bp_sandbox","subtype":"created","sandbox_id":"sbx-epipe"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    sleep #{linger}
    """)

    File.chmod!(path, 0o755)
    {path, go}
  end

  defp queued_output(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    for {port, {:data, data}} when is_port(port) <- messages, into: "", do: data
  end

  # The real event: both frames are in the Session's mailbox. Bounded only as
  # a backstop for a broken stub; the wait ends on the frames, not a budget.
  defp await_queued_frames(pid, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      String.contains?(queued_output(pid), ~s("type":"result")) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the stub's frames never reached the Session's mailbox")

      true ->
        Process.sleep(5)
        await_queued_frames(pid, deadline)
    end
  end

  test "a write into a closed stdin no longer kills the Session: queued frames still reach the sink, then an exit",
       %{dir: dir} do
    {path, go} = stub(dir)
    Application.put_env(:barkpark, :claude_chat, command: {path, []})

    {:ok, session} = ClaudeChat.start_session(%{sink: self(), mode: "plan"})
    ref = Process.monitor(session)

    :ok = :sys.suspend(session)
    # Queued FIRST, ahead of any frame: the order the CI race produced.
    {:ok, _request_id} = ClaudeChat.initialize(session)
    File.write!(go, "")
    :ok = await_queued_frames(session)
    :ok = :sys.resume(session)

    assert_receive {:claude_chat_event, %{"type" => "bp_sandbox", "sandbox_id" => "sbx-epipe"}},
                   5_000

    assert_receive {:claude_chat_event, %{"type" => "result"}}, 5_000
    assert_receive {:claude_chat_exit, :epipe, _stderr_tail}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  defp running?(path),
    do: match?({_, 0}, System.cmd("pgrep", ["-f", path], stderr_to_stdout: true))

  defp await_gone(path, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      not running?(path) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && await_gone(path, deadline)
    end
  end

  test "a CLI that closed its stdin and keeps running is killed when the write kills its port",
       %{dir: dir} do
    # The dead port can no longer name its child, so only the pid the Session
    # read at spawn can end a CLI that lingers 30 s past its EPIPE.
    {path, go} = stub(dir, 30)
    on_exit(fn -> System.cmd("pkill", ["-9", "-f", path]) end)
    Application.put_env(:barkpark, :claude_chat, command: {path, []})

    {:ok, session} = ClaudeChat.start_session(%{sink: self(), mode: "plan"})
    ref = Process.monitor(session)

    :ok = :sys.suspend(session)
    {:ok, _request_id} = ClaudeChat.initialize(session)
    File.write!(go, "")
    :ok = await_queued_frames(session)
    :ok = :sys.resume(session)

    assert_receive {:claude_chat_exit, :epipe, _stderr_tail}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
    assert await_gone(path), "the CLI #{path} outlived its EPIPE"
  end
end
