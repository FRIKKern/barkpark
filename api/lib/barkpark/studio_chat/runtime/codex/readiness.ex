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

  defp version(path, timeout) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(path, ["--version"], stderr_to_stdout: false)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse_version(output)
      {:ok, {_output, _status}} -> {:error, :version_failed}
      {:exit, _reason} -> {:error, :version_failed}
      nil -> {:error, :timeout}
    end
  rescue
    _ -> {:error, :version_failed}
  end

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
