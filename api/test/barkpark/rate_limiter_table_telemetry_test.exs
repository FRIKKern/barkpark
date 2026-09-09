defmodule Barkpark.RateLimiterTableTelemetryTest do
  @moduledoc """
  `@max_entries 10_000` decides whether the prune ever runs, and until these
  events existed nothing outside the private `maybe_prune/1` could observe the
  number it gates on. The guerrilla node is not distributed and ExecStarts a
  bare `mix phx.server`, so there is no `bin/… rpc` route to the live table
  either — the severity of every `@stale_after_ms` argument had to be DERIVED
  from restart cadence instead of read.

  These tests hold the two events and the public reader to their contract.
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.RateLimiter

  setup :reset_rate_limiter!

  @table :barkpark_rate_limiter
  @max_entries 10_000

  setup do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp attach!(event) do
    handler = "rl-#{Enum.join(event, "-")}-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      event,
      fn ^event, measurements, _meta, _ -> send(test_pid, {:event, event, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # Rows stamped `now` are FAR younger than @stale_after_ms (1h), so the stale
  # sweep can never match one — that is the flood shape the ceiling exists for.
  defp plant_fresh!(n, tag) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, for(i <- 1..n, do: {{:token, "#{tag}-#{i}"}, 5.0, now - rem(i, 1000)}))
    :ets.info(@table, :size)
  end

  # Rows stamped older than @stale_after_ms: exactly what the sweep is meant to
  # free, so the `freed` count has something non-zero to report.
  defp plant_stale!(n, tag) do
    now = System.monotonic_time(:millisecond)
    old = now - 3_600_000 - 60_000
    :ets.insert(@table, for(i <- 1..n, do: {{:token, "#{tag}-#{i}"}, 5.0, old - i}))
    :ets.info(@table, :size)
  end

  describe "table_size/0 — the reader that needs no rpc" do
    test "reports the live row count and moves with the table" do
      assert RateLimiter.table_size() == 0

      assert RateLimiter.check({:token, "size-reader"}, capacity: 5, refill_per_sec: 1.0) == :ok
      assert RateLimiter.table_size() == 1

      plant_fresh!(40, "size-reader-flood")
      assert RateLimiter.table_size() == 41
      assert RateLimiter.table_size() == :ets.info(@table, :size)
    end
  end

  describe "[:barkpark, :rate_limiter, :table]" do
    # CRITERION: the size is emitted on the ordinary cold-key path, NOT only
    # once @max_entries is crossed. A measurement that appears only past the
    # threshold cannot answer "how close are we", and its silence would mean
    # both "healthy" and "not instrumented".
    test "fires on a cold-key insert well UNDER the bound, carrying size and limit" do
      attach!([:barkpark, :rate_limiter, :table])
      plant_fresh!(7, "under-bound")

      assert RateLimiter.check({:token, "table-event-cold"}, capacity: 5, refill_per_sec: 1.0) ==
               :ok

      assert_received {:event, [:barkpark, :rate_limiter, :table], m}
      # The size READ BY the prune, i.e. before this call's own insert.
      assert m.size == 7
      assert m.limit == @max_entries
    end

    test "the emitted size tracks the table across successive cold keys" do
      attach!([:barkpark, :rate_limiter, :table])

      for i <- 1..3 do
        RateLimiter.check({:token, "table-track-#{i}"}, capacity: 5, refill_per_sec: 1.0)
        assert_received {:event, [:barkpark, :rate_limiter, :table], m}
        assert m.size == i - 1
      end
    end
  end

  describe "[:barkpark, :rate_limiter, :pruned]" do
    # CRITERION: "does the prune ever run in production" becomes answerable from
    # data — the event names how many rows the STALE SWEEP deleted.
    test "reports the rows the stale sweep deleted when it fires" do
      attach!([:barkpark, :rate_limiter, :pruned])

      stale = @max_entries + 500
      assert plant_stale!(stale, "prune-count") == stale

      assert RateLimiter.check({:token, "prune-trigger"}, capacity: 5, refill_per_sec: 1.0) == :ok

      assert_received {:event, [:barkpark, :rate_limiter, :pruned], m}
      assert m.size_before == stale
      assert m.freed == stale, "every planted row is past the cutoff, so the sweep frees all"
      assert m.remaining == 0
      assert m.limit == @max_entries
      assert m.stale_after_ms == 3_600_000
    end

    # The sweep is allowed to free NOTHING (a fresh-key flood matches no row).
    # That is the case the derivation-from-restart-cadence could not see, so it
    # is exactly the case the number has to report honestly.
    test "reports freed: 0 when every row is too fresh to sweep" do
      attach!([:barkpark, :rate_limiter, :pruned])

      planted = plant_fresh!(@max_entries + 500, "prune-zero")

      RateLimiter.check({:token, "prune-trigger-zero"}, capacity: 5, refill_per_sec: 1.0)

      assert_received {:event, [:barkpark, :rate_limiter, :pruned], m}
      assert m.size_before == planted
      assert m.freed == 0
      assert m.remaining == planted
    end

    # It must not cry wolf: under the bound the prune does no work, so there is
    # nothing to report. (The :table event above still fires — that is the point
    # of splitting them.)
    test "does NOT fire while the table is under the bound" do
      attach!([:barkpark, :rate_limiter, :pruned])
      plant_fresh!(50, "quiet")

      RateLimiter.check({:token, "prune-quiet"}, capacity: 5, refill_per_sec: 1.0)

      refute_received {:event, [:barkpark, :rate_limiter, :pruned], _}
    end
  end
end
