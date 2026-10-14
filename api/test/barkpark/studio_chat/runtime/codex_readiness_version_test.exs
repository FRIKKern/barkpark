defmodule Barkpark.StudioChat.Runtime.CodexReadinessVersionTest do
  @moduledoc """
  task-3d3f89e2966ea9d7 — `Readiness.verify_version/2` shells out to
  `<codex> --version` under a deadline. A binary that hangs there used to be
  ORPHANED on timeout: the BEAM task running `System.cmd` was brutal-killed,
  which closes the port, and a port close sends the child no signal. A hung
  `--version` that does not read stdin kept running, reparented to init.

  The stubs below write their own PID to a file first, so the test can ask the
  OS whether the child outlived the timeout.
  """
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime.Codex.Readiness
  alias Barkpark.TestTmp

  defp stub(body) do
    id = System.unique_integer([:positive])
    path = TestTmp.path("codex_version_stub_#{id}.sh")
    pid_file = TestTmp.path("codex_version_stub_#{id}.pid")
    File.write!(path, "#!/bin/sh\necho $$ > '#{pid_file}'\n" <> body)
    File.chmod!(path, 0o755)

    on_exit(fn ->
      # Belt: never leave a stub running, whatever the assertion said.
      with {:ok, pid} <- read_pid(pid_file), do: System.cmd("kill", ["-9", pid])
      File.rm(path)
      File.rm(pid_file)
    end)

    {path, pid_file}
  end

  defp read_pid(pid_file) do
    case File.read(pid_file) do
      {:ok, body} -> {:ok, String.trim(body)}
      error -> error
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  # The real event: the stub has written its PID (it is running).
  defp await_pid(pid_file, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case read_pid(pid_file) do
      {:ok, pid} when pid != "" ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("the stub never started"),
          else: Process.sleep(10) && await_pid(pid_file, deadline)
    end
  end

  # The kill is delivered asynchronously; wait for the OS to agree, bounded.
  defp await_gone(pid, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      not alive?(pid) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && await_gone(pid, deadline)
    end
  end

  test "a --version that hangs times out AND its OS process is gone afterwards" do
    # Never reads stdin, never answers, lingers far past the deadline.
    {path, pid_file} = stub("exec 0<&-\nsleep 30\n")

    assert {:error, :timeout} = Readiness.verify_version(path, 300)

    pid = await_pid(pid_file)
    assert await_gone(pid), "the timed-out --version child #{pid} was orphaned (still alive)"
  end

  test "a pinned version still verifies" do
    {path, _pid_file} = stub("echo 'codex-cli 0.144.1'\n")
    assert {:ok, "0.144.1"} = Readiness.verify_version(path, 5_000)
  end

  test "a nonzero exit is :version_failed" do
    {path, _pid_file} = stub("echo 'boom' >&2\nexit 3\n")
    assert {:error, :version_failed} = Readiness.verify_version(path, 5_000)
  end

  test "output with no version is :malformed_version" do
    {path, _pid_file} = stub("echo 'no digits here'\n")
    assert {:error, :malformed_version} = Readiness.verify_version(path, 5_000)
  end

  test "an incompatible version is refused" do
    {path, _pid_file} = stub("echo 'codex-cli 0.144.4'\n")
    assert {:error, :incompatible_version} = Readiness.verify_version(path, 5_000)
  end

  test "a missing binary is :version_failed" do
    missing = TestTmp.path("codex_missing_#{System.unique_integer([:positive])}")
    assert {:error, :version_failed} = Readiness.verify_version(missing, 5_000)
  end
end
