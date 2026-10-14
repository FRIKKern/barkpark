defmodule Barkpark.StudioChat.Runtime.CodexHandshakeReapTest do
  @moduledoc """
  task-3d3f89e2966ea9d7, the handshake half: when `Codex.Session.start/1`'s
  startup handshake times out, the app-server's OS process must not outlive
  it. Each stub writes its own PID first, so the test asks the OS.
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

    {path, pid_file}
  end

  defp read_pid(pid_file) do
    case File.read(pid_file) do
      {:ok, body} when body != "" -> {:ok, String.trim(body)}
      {:ok, _empty} -> {:error, :empty}
      error -> error
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  # The kill is asynchronous; wait for the OS to agree, bounded.
  defp await_gone(pid, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      not alive?(pid) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && await_gone(pid, deadline)
    end
  end

  defp start(path),
    do:
      Session.start(%{binary: path, args: [], sink: self(), session_id: "reap", timeout_ms: 300})

  test "a handshake that is never answered times out AND the app-server process is gone" do
    # Reads (and ignores) every request, answers nothing, and then IGNORES the
    # EOF a port close gives it: only a real kill ends it, so a close-only
    # teardown cannot pass this test.
    {path, pid_file} = stub("while IFS= read -r line; do :; done\nsleep 30\n")

    assert {:error, :timeout} = start(path)
    assert {:ok, pid} = read_pid(pid_file)
    assert await_gone(pid), "the timed-out app-server #{pid} was orphaned (still alive)"
  end

  test "an app-server that closed its stdin is reaped too, not left running" do
    # The Session's initialize write meets a closed pipe: the port dies (EPIPE)
    # before the handshake clock fires, so the port can no longer name its pid.
    {path, pid_file} = stub("exec 0<&-\nsleep 30\n")

    assert {:error, _reason} = start(path)
    assert {:ok, pid} = read_pid(pid_file)
    assert await_gone(pid), "the app-server #{pid} with a closed stdin was orphaned (still alive)"
  end
end
