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
    on_exit(fn -> await_not_running() end)
    :ok
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
end
