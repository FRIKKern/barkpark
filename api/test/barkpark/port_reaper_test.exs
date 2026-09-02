defmodule Barkpark.PortReaperTest do
  @moduledoc """
  `Port.close/1` closes the pipe fds and signals the child NOTHING. Every site in
  this tree spawns a program Barkpark does not control the exit behaviour of, so
  a close-only teardown orphans any child that does not exit on stdin EOF
  (GH #6681 — a stub of this shape held two cores for 1d19h).

  These tests assert the OS PROCESS IS GONE, never that `Port.info(port) == nil`
  — the latter passes happily with the kill reverted, which is exactly the
  vacuous shape the filing warned about. "Gone" is read from `ps -o state=`: no
  row at all, or a row in state `Z` (reaped-but-not-waited zombie).

  The child is `sleep`, chosen because it NEVER READS STDIN: closing the port's
  pipes cannot terminate it, so the kill is the only thing that can. Its argument
  carries a unique fractional value so `pgrep -f` addresses exactly one process
  and never a sibling test's child.

  NON-VACUITY, stated as a test rather than a comment: `test "the leak is real"`
  performs a BARE `Port.close/1` and asserts the child is STILL RUNNING
  afterwards. If `alive?/1` ever went blind (wrong pid, wrong ps flags, a
  platform whose ps says nothing) that test fails, so a green file cannot mean
  "the probe sees nothing anywhere".

  MUTATION-PROVED: reverting `Barkpark.PortReaper.kill/1` to a no-op reds every
  reap assertion here and leaves "the leak is real" green.
  """
  use ExUnit.Case, async: false

  alias Barkpark.PortReaper
  alias Barkpark.SelfUpdate.Runner
  alias BarkparkWeb.Studio.ClaudeChat

  # ── probes ────────────────────────────────────────────────────────────────

  # A duration unique to this process+call, used both as the sleep length and as
  # the pgrep needle. Long enough that nothing here can pass by the child simply
  # having finished.
  defp unique_duration, do: "600.#{System.unique_integer([:positive])}"

  # A child that ignores stdin EOF, spawned so that `Port.info(port, :os_pid)`
  # names the sleep ITSELF (no shell in between, so no forked grandchild can
  # survive a kill aimed at the shell).
  defp deaf_child do
    duration = unique_duration()

    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :binary,
        :exit_status,
        args: [duration]
      ])

    os_pid = PortReaper.os_pid(port)
    assert is_integer(os_pid), "no os_pid for a freshly spawned port"
    assert alive?(os_pid), "precondition: the spawned child is running"

    on_exit(fn -> PortReaper.kill(os_pid) end)
    {port, os_pid, duration}
  end

  # `ps -o state=` — an empty answer (or a nonzero exit) means no such process;
  # a `Z` state means reaped-but-not-waited, which is gone for our purposes.
  defp alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        state = String.trim(out)
        state != "" and not String.starts_with?(state, "Z")

      _ ->
        false
    end
  end

  defp await_gone(os_pid, attempts \\ 100) do
    cond do
      not alive?(os_pid) -> true
      attempts <= 0 -> false
      true -> Process.sleep(20) && await_gone(os_pid, attempts - 1)
    end
  end

  defp pgrep(needle) do
    case System.cmd("pgrep", ["-f", needle], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))

      _ ->
        []
    end
  end

  defp await_done(attempts \\ 100) do
    case Runner.status() do
      %{state: :done} -> true
      _ when attempts > 0 -> Process.sleep(20) && await_done(attempts - 1)
      _ -> false
    end
  end

  defp await_pgrep(needle, attempts \\ 100) do
    case pgrep(needle) do
      [pid | _] -> pid
      [] when attempts > 0 -> Process.sleep(20) && await_pgrep(needle, attempts - 1)
      [] -> nil
    end
  end

  # ── the hazard, stated as a test ──────────────────────────────────────────

  test "the leak is real: a bare Port.close leaves the child running" do
    {port, os_pid, _duration} = deaf_child()

    Port.close(port)
    # Generous: if closing the pipes were going to kill it, 300ms is plenty.
    Process.sleep(300)

    assert alive?(os_pid),
           "this test's premise is gone — closing the port terminated the child, " <>
             "so the reap assertions below prove nothing"
  end

  # ── the helper ────────────────────────────────────────────────────────────

  describe "reap/1" do
    test "closes the port AND kills the OS process" do
      {port, os_pid, _duration} = deaf_child()

      assert :ok = PortReaper.reap(port)

      assert await_gone(os_pid),
             "the child survived reap/1 — the port closed but nothing signalled the process"
    end

    test "is total on a port that is already closed" do
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      Port.close(port)

      # Precondition: this is the raising kind of port.
      assert_raise ArgumentError, fn -> Port.close(port) end
      assert :ok = PortReaper.reap(port)
    end

    test "is total on a non-port" do
      assert :ok = PortReaper.reap(nil)
      assert :ok = PortReaper.reap(:not_a_port)
      assert PortReaper.os_pid(nil) == nil
      assert PortReaper.kill(nil) == :ok
    end
  end

  # ── site: the self-update run watchdog ────────────────────────────────────

  describe "SelfUpdate.Runner run-deadline watchdog" do
    setup do
      prior = Application.get_env(:barkpark, Runner)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:barkpark, Runner, prior),
          else: Application.delete_env(:barkpark, Runner)
      end)

      :ok
    end

    # The watchdog fires precisely BECAUSE the child is misbehaving, so it is the
    # sharpest of the sites: a close-only watchdog "recovers" the Runner's run
    # slot while leaving the runaway it fired over still running.
    test "force-closing a run past its deadline reaps the update child" do
      duration = unique_duration()
      dir = Path.join(System.tmp_dir!(), "bp-reaper-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      Application.put_env(
        :barkpark,
        Runner,
        Keyword.merge(Application.get_env(:barkpark, Runner) || [],
          enabled: true,
          command: {"sleep", [duration]},
          run_deadline_ms: 150,
          run_state_dir: dir
        )
      )

      assert Runner.trigger() == {:ok, :started}

      os_pid = await_pgrep(duration)
      assert is_integer(os_pid), "the update child never appeared in ps"
      on_exit(fn -> PortReaper.kill(os_pid) end)

      assert await_done()
      assert Runner.status().exit_code == -2, "the watchdog did not force-close the run"

      assert await_gone(os_pid),
             "the watchdog closed the port but left the runaway update child running"
    end
  end

  # ── site: the Studio chat child ───────────────────────────────────────────

  test "ClaudeChat.Session.terminate reaps the chat child" do
    {port, os_pid, _duration} = deaf_child()

    assert :ok = ClaudeChat.Session.terminate(:normal, %{port: port})

    assert await_gone(os_pid),
           "the chat child outlived its session — terminate closed the port and nothing else"
  end
end
