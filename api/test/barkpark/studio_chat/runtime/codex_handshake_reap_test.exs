defmodule Barkpark.StudioChat.Runtime.CodexHandshakeReapTest do
  @moduledoc """
  task-3d3f89e2966ea9d7, the handshake half: when `Codex.Session.start/1`'s
  startup handshake times out, the app-server's OS process must not outlive
  it. Each stub runs from its own unique path, so the test asks the OS whether
  anything still runs that path; the PID file each stub writes is only for
  cleanup.
  """
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime.Codex.Session
  alias Barkpark.TestTmp

  defp stub(body) do
    id = System.unique_integer([:positive])
    path = TestTmp.path("codex_handshake_stub_#{id}.sh")
    pid_file = TestTmp.path("codex_handshake_stub_#{id}.pid")
    File.write!(path, "#!/bin/sh\necho $$ > '#{pid_file}'\n" <> body)
    File.chmod!(path, 0o755)

    on_exit(fn ->
      with {:ok, pid} <- read_pid(pid_file), do: System.cmd("kill", ["-9", pid])
      File.rm(path)
      File.rm(pid_file)
    end)

    path
  end

  defp read_pid(pid_file) do
    case File.read(pid_file) do
      {:ok, body} when body != "" -> {:ok, String.trim(body)}
      {:ok, _empty} -> {:error, :empty}
      error -> error
    end
  end

  defp running?(path),
    do: match?({_, 0}, System.cmd("pgrep", ["-f", path], stderr_to_stdout: true))

  # The kill is asynchronous; wait for the OS to agree, bounded. Asking by path,
  # not by the PID the stub writes, keeps this true for a stub killed before its
  # first line ran: under load the 300 ms clock can fire before `sh` starts, and
  # a missing PID file then failed the test with nothing left running.
  defp await_gone(path, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      not running?(path) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && await_gone(path, deadline)
    end
  end

  defp start(path),
    do:
      Session.start(%{binary: path, args: [], sink: self(), session_id: "reap", timeout_ms: 300})

  test "a handshake that is never answered times out AND the app-server process is gone" do
    # Reads (and ignores) every request, answers nothing, and then IGNORES the
    # EOF a port close gives it: only a real kill ends it, so a close-only
    # teardown cannot pass this test.
    path = stub("while IFS= read -r line; do :; done\nsleep 30\n")

    assert {:error, :timeout} = start(path)
    assert await_gone(path), "the timed-out app-server #{path} was orphaned (still alive)"
  end

  test "an app-server that closed its stdin is reaped too, not left running" do
    # The Session's initialize write meets a closed pipe: the port dies (EPIPE)
    # before the handshake clock fires, so the port can no longer name its pid.
    path = stub("exec 0<&-\nsleep 30\n")

    assert {:error, _reason} = start(path)

    assert await_gone(path),
           "the app-server #{path} with a closed stdin was orphaned (still alive)"
  end

  test "an app-server that closes its stdin BEFORE the next write is reaped too" do
    # The test above races: it meets EPIPE only when the stub closes stdin
    # before the Session's first write, which happened on a loaded CI runner
    # (main 9b76b4bfc9) and almost never on an idle one. This stub closes stdin
    # and only THEN answers `initialize`, so the `initialized` write that
    # follows always meets a closed pipe and the port dies before any reap can
    # read its pid from it.
    path = stub("IFS= read -r line\nexec 0<&-\necho '{\"id\":1,\"result\":{}}'\nsleep 30\n")

    assert {:error, _reason} = start(path)
    assert await_gone(path), "the app-server #{path} that closed stdin mid-handshake was orphaned"
  end

  test "a port that dies on EPIPE ends the handshake at once, not on the clock" do
    # Stdin closes before the `account/read` answer, so the ONE write after it
    # (the thread open) kills the port and nothing else is written: no crash
    # stops the Session, only the port's exit signal can. On the clock it would
    # run 10 s with the child alive and its pid going stale.
    path =
      stub(
        "IFS= read -r line\necho '{\"id\":1,\"result\":{}}'\n" <>
          "IFS= read -r line\nIFS= read -r line\nexec 0<&-\n" <>
          "echo '{\"id\":2,\"result\":{\"requiresOpenaiAuth\":false}}'\nsleep 30\n"
      )

    result =
      Session.start(%{
        binary: path,
        args: [],
        sink: self(),
        session_id: "reap",
        timeout_ms: 10_000
      })

    assert {:error, reason} = result
    refute reason == :timeout, "the handshake waited out its clock on a dead port"
    assert await_gone(path), "the app-server #{path} whose port died on EPIPE was orphaned"
  end

  test "an app-server that exited is never signalled by its spawn pid" do
    # Once the exit status arrives the child is gone and its pid may be reused,
    # so the reap that follows must not carry it. The trace reads the pid the
    # Session hands PortReaper.reap/2; the kill itself would hit nothing here.
    path = stub("IFS= read -r line\nexit 3\n")
    # A trace pattern binds only to LOADED code: in a VM where nothing has
    # called PortReaper yet it matches nothing and no trace ever arrives.
    Code.ensure_loaded!(Barkpark.PortReaper)
    assert :erlang.trace_pattern({Barkpark.PortReaper, :reap, 2}, true, [:local]) == 1
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    on_exit(fn -> :erlang.trace_pattern({Barkpark.PortReaper, :reap, 2}, false, [:local]) end)

    assert {:error, _reason} = start(path)
    assert_receive {:trace, _session, :call, {Barkpark.PortReaper, :reap, [_port, known]}}, 5_000
    assert known == nil, "the Session reaped an exited app-server by its stale pid #{known}"
  end
end
