defmodule Barkpark.StudioChat.Runtime.Codex.Readiness do
  @moduledoc false

  alias Barkpark.StudioChat.Runtime.Codex.Session

  @pinned_version "0.144.1"

  def pinned_version, do: @pinned_version

  def resolve_binary(binary) when is_binary(binary) do
    case System.find_executable(binary) || absolute_executable(binary) do
      nil -> {:error, :binary_missing}
      path -> {:ok, path}
    end
  end

  def verify_version(path, timeout) when is_binary(path) do
    with {:ok, version} <- version(path, timeout),
         :ok <- compatible(version) do
      {:ok, version}
    end
  end

  def probe(path, opts \\ %{}) when is_binary(path) do
    timeout = Map.get(opts, :timeout_ms, 15_000)

    with {:ok, path} <- resolve_binary(path),
         {:ok, version} <- verify_version(path, timeout),
         {:ok, readiness} <-
           Session.probe(%{
             binary: path,
             args: Map.get(opts, :args, ["app-server", "--stdio"]),
             timeout_ms: timeout
           }) do
      {:ok, Map.merge(readiness, %{binary: true, path: path, version: version})}
    end
  end

  # Bounded `--version` shell-out. The task owns a PORT (not `System.cmd`) so
  # that on its own deadline it can REAP the child: `PortReaper.reap/1` closes
  # the port and SIGKILLs the OS pid (task-3d3f89e2966ea9d7). The old shape ran
  # `System.cmd` in the task and `Task.shutdown(:brutal_kill)`ed it on timeout;
  # that closes the port, and a port close sends the child NO signal, so a
  # hung `--version` that does not read stdin was orphaned to init.
  #
  # The task's own deadline fires first; the caller's `Task.yield` outlives it
  # by a second only as a backstop. `path` comes from resolve_binary/1 (a
  # server-configured binary, never request data) and the argv is the fixed
  # ["--version"].
  defp version(path, timeout) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        run_version(path, timeout)
      end)

    case Task.yield(task, yield_timeout(timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :version_failed}
      nil -> {:error, :timeout}
    end
  end

  defp yield_timeout(:infinity), do: :infinity
  defp yield_timeout(ms) when is_integer(ms), do: ms + 1_000

  defp run_version(path, timeout) do
    port = Port.open({:spawn_executable, path}, [:binary, :exit_status, args: ["--version"]])

    deadline =
      if is_integer(timeout), do: Process.send_after(self(), {:version_deadline, port}, timeout)

    collect_version(port, "", deadline)
  rescue
    _ -> {:error, :version_failed}
  end

  defp collect_version(port, acc, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect_version(port, acc <> data, deadline)

      {^port, {:exit_status, 0}} ->
        cancel_deadline(deadline)
        parse_version(acc)

      {^port, {:exit_status, _status}} ->
        cancel_deadline(deadline)
        {:error, :version_failed}

      {:version_deadline, ^port} ->
        Barkpark.PortReaper.reap(port)
        {:error, :timeout}
    end
  end

  defp cancel_deadline(nil), do: :ok
  defp cancel_deadline(ref), do: Process.cancel_timer(ref)

  defp parse_version(output) do
    case Regex.run(~r/\d+(?:\.\d+)+/, output) do
      [version | _] -> {:ok, version}
      _ -> {:error, :malformed_version}
    end
  end

  defp compatible(@pinned_version), do: :ok
  defp compatible(_version), do: {:error, :incompatible_version}

  defp absolute_executable(path) do
    if Path.type(path) == :absolute and File.exists?(path), do: path
  end
end
