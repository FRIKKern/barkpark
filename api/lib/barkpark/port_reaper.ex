defmodule Barkpark.PortReaper do
  @moduledoc """
  Close a `{:spawn_executable, _}` port AND reap the OS process behind it.

  `Port.close/1` closes the pipe fds and sends the child NO signal. It therefore
  terminates only a program that exits on stdin EOF or dies to SIGPIPE — which is
  most of them, but not all. A child that ignores EOF is left running, reparented
  to init, burning whatever CPU it was burning (GH #6681: a test stub of exactly
  this shape held two cores for 1d19h). Every close site in this tree spawns a
  program whose exit behaviour Barkpark does not control, so "the port is closed"
  is never enough: the OS process must be signalled too.

  The ordering is the whole point and it is not optional:

      os_pid = Port.info(port, :os_pid)   # WHILE the port is still open
      Port.close(port)                    # rescued — a raced close raises badarg
      kill -9 os_pid                      # best-effort

  The pid is read while the port is open and never remembered from spawn time:
  `Port.info/2` answers `nil` once the port is closed, and a pid cached earlier
  may since have been reaped and recycled onto an unrelated process.

  There is no membership test (`if Port.info(port)`, `if port in Port.list()`)
  before the close. That is a check-then-act whose window widens under load — the
  port can die inside it, `Port.close/1` then raises `ArgumentError`, and callers
  that wrapped a whole teardown body in one rescue silently skipped everything
  after the close (task-2f44ed9d10be629f, task-95b4b28a56583b1c). The rescue is
  confined to the close alone; the kill and the caller's own cleanup always run.

  This is a straight lift of `Barkpark.StudioChat.Runtime.Codex.Session.reap_port/1`
  — the one site that already reaped — extracted so the remaining sites stop being
  copies of the three lines that matter.
  """

  # @canonical capability:port-child-reap aka:Port.close,reap_port,close_port,kill_os_process,orphan,orphaned child,SIGKILL,os_pid
  @doc """
  Close `port` and SIGKILL the OS process it spawned. Total: never raises, never
  exits, whatever state the port is in (already closed, never opened, not a port).
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
    :ok
  end

  def reap(_not_a_port), do: :ok

  @doc """
  The OS pid behind an OPEN port, or `nil` (closed port, no external process).
  """
  @spec os_pid(port() | term()) :: pos_integer() | nil
  def os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def os_pid(_not_a_port), do: nil

  # Best-effort by design: the child has usually already exited on EOF, in which
  # case `kill` just reports "no such process". A missing `kill` binary or a
  # racing reap must never take the calling process (or its terminate/2) down.
  #
  # Sobelow CI.System is a false positive: the only argument is an integer pid
  # read out of `Port.info/2`, rendered with `Integer.to_string/1`. No shell
  # string, no request data, no caller-supplied binary can reach this argv.
  @spec kill(pos_integer() | nil) :: :ok
  def kill(nil), do: :ok

  # sobelow_skip ["CI.System"]
  def kill(os_pid) when is_integer(os_pid) and os_pid > 0 do
    _ = os_pid
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def kill(_other), do: :ok
end
