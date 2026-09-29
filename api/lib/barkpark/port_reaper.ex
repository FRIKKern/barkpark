defmodule Barkpark.PortReaper do
  @moduledoc """
  Close a `{:spawn_executable, _}` port AND end the OS process behind it.

  Closing such a port closes the pipe fds and sends the child NO signal. It
  terminates only a program that exits on stdin EOF or dies to SIGPIPE; one that
  does neither (a `sleep`, a hung build, a provider stuck in a loop) keeps
  running with its pipes closed, orphaned. GH #6681 measured that on the Codex
  runtime: a stub of that shape held two cores for 1d19h.

  So `reap/1` does three things, in this order (task-aa975de15eff4e6b):

    1. read the child's pid WHILE the port is still open (`Port.info/2` answers
       nil once it is closed, and a pid remembered from spawn time may since have
       been reaped and recycled onto an unrelated process);
    2. close the port, tolerating one that already died (`Port.close/1` raises
       badarg on a dead port, and that raise must never skip step 3);
    3. SIGKILL the pid, best-effort. The child has usually already exited on EOF,
       in which case `kill` just reports "no such process".

  Never raises. This is the ONE place in `api/lib` that calls `Port.close/1`:
  every site that owns a spawned program goes through here.
  """

  @doc """
  Close `port` and SIGKILL its OS process. Returns `:ok` whatever happened.
  """
  @spec reap(port() | term()) :: :ok
  def reap(port) when is_port(port) do
    os_pid = os_pid(port)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    kill(os_pid)
  end

  def reap(_not_a_port), do: :ok

  @doc """
  The OS pid behind an OPEN port, or nil (closed port, not a spawned program).
  """
  @spec os_pid(port()) :: pos_integer() | nil
  def os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Best-effort: a missing `kill` binary or a racing reap must never take the
  # caller (a watchdog, a terminate/2) down with it.
  defp kill(nil), do: :ok

  defp kill(os_pid) when is_integer(os_pid) do
    _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
