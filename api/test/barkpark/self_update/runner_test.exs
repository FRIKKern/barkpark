defmodule Barkpark.SelfUpdate.RunnerTest do
  @moduledoc """
  Unit tests for the rollback additions to `Barkpark.SelfUpdate.Runner`:
  `preflight_rollback/0` exit-code mapping + sha parse, and the fact that
  rollback shares ONE single-flight run slot with self-update. Stub commands
  only — never the real deploy script.
  """
  # async: false — mutates the singleton Runner + Application env.
  use ExUnit.Case, async: false

  alias Barkpark.SelfUpdate.Runner

  @sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    await_not_running()

    # Every test gets its own run-record dir + deploy-rebuild flight record path,
    # so no test writes into the checkout and no test reads another's records.
    dir =
      Path.join(System.tmp_dir!(), "bp-self-update-runs-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    status_file = Path.join(dir, "deploy-status.json")
    put_cfg(run_state_dir: dir, deploy_status_file: status_file, orphan_poll_ms: 50)
    on_exit(fn -> File.rm_rf(dir) end)
    # Registered LAST so it runs FIRST (on_exit is LIFO): a run still in flight
    # finishes while this test's dir + config are still in place.
    on_exit(fn -> await_not_running() end)
    {:ok, dir: dir, status_file: status_file}
  end

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, Runner)
    Application.put_env(:barkpark, Runner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Runner, prior),
        else: Application.delete_env(:barkpark, Runner)
    end)
  end

  defp await_not_running(attempts \\ 60) do
    case Runner.status() do
      %{state: :running} when attempts > 0 ->
        Process.sleep(50)
        await_not_running(attempts - 1)

      _ ->
        :ok
    end
  end

  defp await_done(attempts \\ 40) do
    case Runner.status() do
      %{state: :done} = s -> s
      _ when attempts > 0 -> Process.sleep(50) && await_done(attempts - 1)
      s -> s
    end
  end

  describe "preflight_rollback/0" do
    test "exit 0 parses TARGET_SHA=" do
      put_cfg(
        rollback_preflight_command:
          {"bash", ["-c", "echo TARGET_SLOT=blue; echo TARGET_SHA=#{@sha}; exit 0"]}
      )

      assert Runner.preflight_rollback() == {:ok, @sha}
    end

    test "exit 21 → :no_previous_slot" do
      put_cfg(rollback_preflight_command: {"bash", ["-c", "exit 21"]})
      assert Runner.preflight_rollback() == {:error, :no_previous_slot}
    end

    test "exit 22 → :not_supported" do
      put_cfg(rollback_preflight_command: {"bash", ["-c", "exit 22"]})
      assert Runner.preflight_rollback() == {:error, :not_supported}
    end

    test "exit 23 → :already_running" do
      put_cfg(rollback_preflight_command: {"bash", ["-c", "exit 23"]})
      assert Runner.preflight_rollback() == {:error, :already_running}
    end

    test "exit 0 without a sha fails closed" do
      put_cfg(rollback_preflight_command: {"bash", ["-c", "echo nope; exit 0"]})
      assert {:error, {:preflight_failed, _}} = Runner.preflight_rollback()
    end

    test "any other exit fails closed" do
      put_cfg(rollback_preflight_command: {"bash", ["-c", "exit 7"]})
      assert {:error, {:preflight_failed, 7}} = Runner.preflight_rollback()
    end

    test "a missing executable is rescued, never raised" do
      put_cfg(rollback_preflight_command: {"barkpark-no-such-binary-xyz", []})
      assert {:error, {:preflight_failed, _}} = Runner.preflight_rollback()
    end
  end

  describe "preflight_rollback/0 is time-boxed (resource bound)" do
    # FAIL-BEFORE: preflight called System.cmd directly, so this sleeper blocks the
    # admin request for the full 2s. PASS-AFTER: the child is brutal-killed at the
    # 150ms deadline and preflight fails closed with a bounded error, quickly.
    test "a hung preflight is force-killed at the deadline and fails closed" do
      put_cfg(
        rollback_preflight_command: {"bash", ["-c", "sleep 2"]},
        preflight_timeout_ms: 150
      )

      {micros, result} = :timer.tc(fn -> Runner.preflight_rollback() end)

      assert {:error, {:preflight_failed, {:preflight_timeout, 150}}} = result

      assert micros < 1_500_000,
             "preflight blocked #{micros}µs — the deadline did not bound System.cmd"
    end
  end

  describe "trigger/0 run watchdog (resource bound)" do
    # FAIL-BEFORE: no watchdog, so a `sleep 5` run holds state :running (and thus
    # running?=true) for the full 5s. PASS-AFTER: the deadline watchdog force-closes
    # the port at 150ms, flipping the run to :done so running? can't wedge true.
    test "a run that outlives the deadline is force-closed so running? can't wedge" do
      put_cfg(
        enabled: true,
        command: {"bash", ["-c", "sleep 5"]},
        run_deadline_ms: 150
      )

      assert Runner.trigger() == {:ok, :started}

      status = await_done()
      assert status.state == :done
      # -2 is the watchdog's force-close code, distinct from a natural exit status.
      assert status.exit_code == -2
      refute Runner.running?()
    end
  end

  describe "trigger_rollback/0 single-flight" do
    test "disabled runner refuses" do
      put_cfg(enabled: false)
      assert Runner.trigger_rollback() == {:error, :disabled}
    end

    test "rollback and self-update share one run slot" do
      put_cfg(
        enabled: true,
        command: {"bash", ["-c", "sleep 2"]},
        rollback_command: {"bash", ["-c", "echo rb"]}
      )

      assert Runner.trigger() == {:ok, :started}
      assert Runner.running?()
      # Collision from the other direction.
      assert Runner.trigger_rollback() == {:error, :already_running}
    end

    test "a completed rollback reports mode: :rollback" do
      put_cfg(enabled: true, rollback_command: {"bash", ["-c", "echo done-rb"]})
      assert Runner.trigger_rollback() == {:ok, :started}
      assert await_done().mode == :rollback
    end
  end

  describe "durable run records survive a Runner restart" do
    # The default command RESTARTS the service that owns the Runner, so the
    # process that started a run is never the one asked about it. "Restart" here
    # is the supervisor stopping and starting the Runner child — the same
    # init/1 a rebooted BEAM runs. terminate/restart_child does not count
    # against the supervisor's restart intensity (a :kill would).
    #
    # RED on origin/main: init/1 returned a blank state, so every assertion
    # below read `state: :idle`, `exit_code: nil`, `log: []`.

    test "a finished run reports its real outcome after the restart, not :idle", %{dir: dir} do
      put_cfg(
        enabled: true,
        command: {"bash", ["-c", "echo rebuilding; echo migrate-failed; exit 13"]}
      )

      assert Runner.trigger() == {:ok, :started}
      before = await_done()
      assert before.exit_code == 13

      restart_runner()

      after_restart = Runner.status()
      assert after_restart.state == :done
      assert after_restart.exit_code == 13
      assert after_restart.mode == :self_update
      assert after_restart.log == ["rebuilding", "migrate-failed"]
      assert after_restart.started_at == before.started_at
      assert after_restart.finished_at == before.finished_at

      assert File.exists?(Path.join(dir, "run.manifest.json"))
      assert File.exists?(Path.join(dir, "run.terminal.json"))
    end

    test "a run killed with the BEAM recovers deploy-rebuild's applied record as exit 0",
         %{status_file: status_file} do
      # The script writes deploy-rebuild's flight record under ITS OWN pid ($$),
      # exactly as `write_status restart applied` does just before the restart,
      # then waits to be killed by it.
      script = """
      echo "[deploy-rebuild] swapped + migrated"
      printf '{"engine":"deploy-rebuild","phase":"restart","outcome":"applied","sha":"abc1234","ts":"%s","pid":%d}\\n' \\
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" > #{status_file}
      echo "[deploy-rebuild] Restarting service..."
      exec sleep 30
      """

      put_cfg(enabled: true, command: {"bash", ["-c", script]})
      assert Runner.trigger() == {:ok, :started}
      await_log_line("Restarting service")
      pid = manifest_os_pid()

      # The cgroup kill: the service stop takes the Runner AND the script.
      stop_runner()
      kill_child(pid)
      start_runner()

      status = await_done()
      assert status.state == :done
      assert status.exit_code == 0
      assert "[deploy-rebuild] Restarting service..." in status.log
      assert Enum.any?(status.log, &(&1 =~ "phase=restart outcome=applied sha=abc1234"))
      refute Runner.running?()

      # The recovered outcome is itself recorded — a second boot agrees.
      restart_runner()
      assert %{state: :done, exit_code: 0} = Runner.status()
    end

    test "a run killed with the BEAM and no flight record is interrupted (-3), never :idle" do
      put_cfg(enabled: true, command: {"bash", ["-c", "echo half-way; exec sleep 30"]})
      assert Runner.trigger() == {:ok, :started}
      await_log_line("half-way")
      pid = manifest_os_pid()

      stop_runner()
      kill_child(pid)
      start_runner()

      status = await_done()
      assert status.state == :done
      assert status.exit_code == -3
      assert "half-way" in status.log
      assert Enum.any?(status.log, &(&1 =~ "outcome unknown"))
    end

    test "a flight record from a different pid is not adopted", %{status_file: status_file} do
      File.write!(
        status_file,
        ~s({"engine":"deploy-rebuild","phase":"restart","outcome":"applied","sha":"x","ts":"2099-01-01T00:00:00Z","pid":1})
      )

      put_cfg(enabled: true, command: {"bash", ["-c", "echo go; exec sleep 30"]})
      assert Runner.trigger() == {:ok, :started}
      await_log_line("go")
      pid = manifest_os_pid()

      stop_runner()
      kill_child(pid)
      start_runner()

      assert %{state: :done, exit_code: -3} = await_done()
    end

    test "a child that outlives the Runner is re-attached as :running and holds the slot" do
      put_cfg(enabled: true, command: {"bash", ["-c", "echo alive; exec sleep 30"]})
      assert Runner.trigger() == {:ok, :started}
      await_log_line("alive")
      pid = manifest_os_pid()

      restart_runner()

      assert %{state: :running, log: ["alive"]} = Runner.status()
      assert Runner.trigger() == {:error, :already_running}

      # Once the child exits, the poll finalizes the run.
      kill_child(pid)
      assert %{state: :done, exit_code: -3} = await_done()
    end

    test "status/0 reads the records when the Runner process is down" do
      put_cfg(enabled: true, command: {"bash", ["-c", "echo from-disk; exit 1"]})
      assert Runner.trigger() == {:ok, :started}
      await_done()

      stop_runner()

      try do
        assert %{state: :done, exit_code: 1, log: ["from-disk"]} = Runner.status()
      after
        start_runner()
      end
    end

    test "secret-shaped output never reaches the records", %{dir: dir} do
      pat = "bppat_7Kd-Qm2xTf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB"
      put_cfg(enabled: true, command: {"bash", ["-c", "echo BARKPARK_TOKEN=#{pat}; exit 0"]})
      assert Runner.trigger() == {:ok, :started}
      await_done()

      for file <- ["run.log", "run.terminal.json"] do
        body = File.read!(Path.join(dir, file))
        refute body =~ pat, "#{file} holds the raw token"
        assert body =~ "BARKPARK_TOKEN="
      end

      refute Enum.any?(Runner.status().log, &(&1 =~ pat))
    end
  end

  defp stop_runner, do: :ok = Supervisor.terminate_child(Barkpark.Supervisor, Runner)

  defp start_runner do
    case Supervisor.restart_child(Barkpark.Supervisor, Runner) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  defp restart_runner do
    stop_runner()
    start_runner()
  end

  defp manifest_os_pid do
    dir = Keyword.fetch!(Application.get_env(:barkpark, Runner), :run_state_dir)
    %{"os_pid" => pid} = dir |> Path.join("run.manifest.json") |> File.read!() |> Jason.decode!()
    assert is_integer(pid)
    pid
  end

  # Kill exactly the child this test spawned (its pid from the manifest the
  # Runner wrote) — the in-test stand-in for systemd's cgroup kill.
  defp kill_child(pid) do
    System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    await_pid_gone(pid)
  end

  defp await_pid_gone(pid, attempts \\ 40) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 -> Process.sleep(25) && await_pid_gone(pid, attempts - 1)
      _ -> :ok
    end
  end

  defp await_log_line(fragment, attempts \\ 60) do
    status = Runner.status()

    cond do
      Enum.any?(status.log, &String.contains?(&1, fragment)) -> status
      attempts > 0 -> Process.sleep(50) && await_log_line(fragment, attempts - 1)
      true -> flunk("log never showed #{inspect(fragment)}: #{inspect(status)}")
    end
  end
end
