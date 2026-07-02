defmodule Barkpark.Plugins.Indx.MonitorTest do
  @moduledoc """
  Covers the P4b Hardening A Indx outcome monitor — per-scope counters
  for `bp doctor`, a canonical telemetry event for ops handlers, and
  the constant-time snapshot read path used by both surfaces.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Indx.Monitor

  @event [:barkpark, :indx, :retriever, :outcome]

  setup do
    # Monitor is started by the host supervision tree; reset to keep snapshots
    # hermetic across tests.
    Monitor.reset()

    test_pid = self()

    handler_id = "monitor-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @event,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "snapshot of an unseen scope is all zeros + nil last-error fields" do
    snap = Monitor.snapshot("nothing-yet")
    assert snap.scope == "nothing-yet"
    assert snap.success == 0
    assert snap.fallback == 0
    assert snap.total == 0
    assert snap.fallback_rate == 0.0
    assert snap.last_error_at == nil
    assert snap.last_error_reason == nil
    assert snap.last_error_status == nil
  end

  test "record_success increments success counter + emits telemetry" do
    assert :ok = Monitor.record_success("production", %{dataset: "bp_production_v3"})

    snap = Monitor.snapshot("production")
    assert snap.success == 1
    assert snap.fallback == 0
    assert snap.fallback_rate == 0.0

    assert_receive {:telemetry, @event, %{count: 1}, meta}, 200
    assert meta.scope == "production"
    assert meta.kind == :success
    assert meta.dataset == "bp_production_v3"
  end

  test "record_fallback increments fallback counter + stamps last_error" do
    err = %{code: :timeout, message: "indx unreachable"}

    assert :ok =
             Monitor.record_fallback("production", err, %{
               dataset: "bp_production_v3",
               status: 504
             })

    snap = Monitor.snapshot("production")
    assert snap.success == 0
    assert snap.fallback == 1
    assert snap.total == 1
    assert snap.fallback_rate == 1.0
    assert snap.last_error_status == 504
    assert is_binary(snap.last_error_reason)
    assert snap.last_error_reason =~ "timeout"
    assert %DateTime{} = snap.last_error_at

    assert_receive {:telemetry, @event, %{count: 1}, meta}, 200
    assert meta.kind == :fallback
    assert meta.scope == "production"
    assert meta.reason == err
    assert meta.status == 504
  end

  test "fallback_rate over a mixed history" do
    for _ <- 1..7, do: Monitor.record_success("p")
    for _ <- 1..3, do: Monitor.record_fallback("p", :err, %{})

    snap = Monitor.snapshot("p")
    assert snap.success == 7
    assert snap.fallback == 3
    assert snap.total == 10
    assert_in_delta snap.fallback_rate, 0.3, 0.001
  end

  test "atomic increments under concurrent recorders" do
    # 50 tasks each recording 10 outcomes. With the atomic
    # :ets.update_counter, no increments are lost.
    tasks =
      for i <- 1..50 do
        Task.async(fn ->
          for _ <- 1..10 do
            if rem(i, 2) == 0,
              do: Monitor.record_success("race"),
              else: Monitor.record_fallback("race", :err, %{})
          end
        end)
      end

    Enum.each(tasks, &Task.await/1)

    snap = Monitor.snapshot("race")
    assert snap.total == 500
    assert snap.success == 250
    assert snap.fallback == 250
  end

  test "table stays bounded and keeps recording across the clear-on-full wipe" do
    max_rows = 30_000
    # 3 rows/scope (success, fallback, last_error), so this many distinct
    # scopes overshoots @max_rows and forces at least one wholesale wipe.
    scope_count = div(max_rows, 3) + 50

    for i <- 1..scope_count do
      scope = "scope-#{i}"
      Monitor.record_success(scope)
      Monitor.record_fallback(scope, :err, %{})
      # Invariant holds at every step: never exceeds the cap.
      assert :ets.info(:barkpark_indx_monitor, :size) <= max_rows
    end

    assert :ets.info(:barkpark_indx_monitor, :size) <= max_rows

    # Recording still works after the wipe: a fresh scope reads clean counts.
    fresh = "post-wipe-scope"
    Monitor.record_success(fresh)
    snap = Monitor.snapshot(fresh)
    assert snap.success == 1
    assert :ets.info(:barkpark_indx_monitor, :size) <= max_rows
  end

  test "snapshot_all returns every scope, sorted with most-recent-error first" do
    Monitor.record_success("alpha")
    Monitor.record_fallback("beta", :older, %{})
    # Force a later timestamp on the second fallback.
    Process.sleep(5)
    Monitor.record_fallback("gamma", :newer, %{})

    snaps = Monitor.snapshot_all()
    scopes = Enum.map(snaps, & &1.scope)

    # gamma's error is the most recent → first; alpha has no error → ordered last.
    assert Enum.at(scopes, 0) == "gamma"
    assert "alpha" in scopes
    assert "beta" in scopes
  end
end
