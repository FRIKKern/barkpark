defmodule Barkpark.Test.OsProcess do
  @moduledoc """
  Test helpers for asserting an OS process is GONE (task-aa975de15eff4e6b).

  `kill -0` cannot answer "is it gone": it succeeds on a zombie, and a SIGKILLed
  child is a zombie until the BEAM's erl_child_setup reaps it. `alive?/1` reads
  the `ps` state column instead and counts `Z` as gone (it holds no CPU and no
  fds). Never assert `Port.info(port) == nil` for this — that passes happily with
  the kill reverted.
  """

  @doc "True while `os_pid` is a live, non-zombie process."
  @spec alive?(integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        state = String.trim(out)
        state != "" and not String.starts_with?(state, "Z")

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc "Poll until `os_pid` is gone; true if it went within `timeout_ms`."
  @spec gone_within?(integer(), non_neg_integer()) :: boolean()
  def gone_within?(os_pid, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_gone(os_pid, deadline)
  end

  defp poll_gone(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        poll_gone(os_pid, deadline)
    end
  end

  @doc """
  Read the pid a stub wrote with `echo $$ > path; exec …` (the pid survives the
  `exec`), waiting up to `timeout_ms` for it to appear. nil if it never did.
  """
  @spec read_pid_file(Path.t(), non_neg_integer()) :: integer() | nil
  def read_pid_file(path, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_pid_file(path, deadline)
  end

  defp poll_pid_file(path, deadline) do
    with {:ok, body} <- File.read(path),
         {pid, _} <- Integer.parse(String.trim(body)) do
      pid
    else
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(20)
          poll_pid_file(path, deadline)
        end
    end
  end

  @doc "Best-effort SIGKILL — the belt for a test that fails before its assertion."
  @spec kill(integer() | nil) :: :ok
  def kill(nil), do: :ok

  def kill(os_pid) do
    _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
