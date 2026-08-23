defmodule Barkpark.Tenancy.WorkspaceBundleJanitorPsBoundTest do
  @moduledoc """
  The janitor's `ps` liveness probe is BOUNDED (task-felix-w21-bl-janitor-ps-bound).

  Before the bound, `os_process_alive?/2` was a synchronous `System.cmd` with
  no timeout. The rescue around `sweep/1` never covers that shape — a blocked
  port read raises nothing — so ONE wedged `ps` hung the boot-time sweep Task
  forever and every remaining candidate went unevaluated (the leak the janitor
  exists to collect survived until an operator noticed).

  The proof drives a real sweep against a sleep-stub `ps`:

    * the sweep RETURNS within the test's own bound (an unbounded probe makes
      `Task.yield/2` answer `nil` here — that is the red this test produces on
      the pre-fix code);
    * the wedged candidate is answered ALIVE and KEPT (`skipped_live`) — a
      timeout must never let the janitor delete a possibly-live export;
    * the candidate AFTER the wedged one is still evaluated and collected —
      the sweep advances, which is the entire point of the bound.

  Uses `ExUnit.Case` (no DB) like the sibling janitor suite; async: true is
  safe — every option is passed explicitly, no global env is touched.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tenancy.WorkspaceBundle.Janitor

  @max_age 3600

  setup do
    dir =
      Path.join([
        System.tmp_dir!(),
        "bp-janitor-psbound-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # A `ps` that wedges: sleeps far past every bound in play. The sweep under
    # test must not wait for it.
    stub = Path.join(dir, "wedged-ps.sh")
    File.write!(stub, "#!/bin/sh\nsleep 60\n")
    File.chmod!(stub, 0o755)

    {:ok, dir: dir, stub: stub}
  end

  defp seed(dir, name, age_seconds) do
    path = Path.join(dir, name)
    File.write!(path, "x")
    File.touch!(path, System.os_time(:second) - age_seconds)
    path
  end

  test "the sweep advances past a wedged ps probe and keeps the probed file", %{
    dir: dir,
    stub: stub
  } do
    # Candidate 1 (bundle prefix sorts first in candidates/1): stale AND
    # owner-marked, so the sweep MUST probe it — through the wedged stub.
    wedged = seed(dir, "bp-ws-bundle-wedge.tar", @max_age + 600)
    File.write!(wedged <> ".owner", Integer.to_string(:os.getpid() |> List.to_integer()))

    # Candidate 2: stale and unowned — collectable, but only reached if the
    # sweep survives candidate 1.
    after_wedge = seed(dir, "bp-ws-spill-after.copy", @max_age + 600)

    sweep_task =
      Task.async(fn ->
        Janitor.sweep(
          dir: dir,
          max_age_seconds: @max_age,
          ps_path: stub,
          ps_timeout_ms: 100
        )
      end)

    case Task.yield(sweep_task, 5_000) || Task.shutdown(sweep_task, :brutal_kill) do
      nil ->
        flunk(
          "sweep did not return within 5s against a wedged ps — " <>
            "the liveness probe is UNBOUNDED and one hung `ps` stalls the whole collection"
        )

      {:ok, {:ok, result}} ->
        # Fail-safe direction: a probe that timed out answers ALIVE, so the
        # wedged candidate is skipped, never deleted.
        assert result.skipped_live == 1
        assert File.exists?(wedged), "a timed-out probe must never cost a possibly-live export"

        # THE ADVANCEMENT PROOF: the candidate behind the wedge was still
        # evaluated and collected.
        assert result.removed == [after_wedge]
        refute File.exists?(after_wedge)
    end
  end
end
