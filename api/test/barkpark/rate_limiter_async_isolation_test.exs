defmodule Barkpark.RateLimiterAsyncIsolationTest do
  @moduledoc """
  THE RATCHET for `Barkpark.RateLimiter`'s whole-node ETS seam.

  `:barkpark_rate_limiter` is a `:named_table` (rate_limiter.ex:26/50-56): node
  state, not process state. The SQL sandbox does not own it, nothing rolls it
  back, and before this task nothing in `api/test/support` reset it. A bucket one
  test spent stayed spent for every test after it, and the suite's own keys are
  short literals (`{:token, "a"}` at capacity 1), so an assertion's truth depended
  on execution order.

  Two things are pinned here, both derived from the tree rather than hand-listed:

    1. every test file that touches the limiter is `async: false` — the reset is
       only safe because no peer can be running concurrently; and
    2. every such file actually calls the reset.

  Plus a live demonstration that the contamination is real, and that the reset is
  what removes it — so this file is not merely asserting about text.
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.{RateLimiter, RateLimiterSandbox}

  setup :reset_rate_limiter!

  @test_root Path.expand("../..", __DIR__) |> Path.join("test")

  # Files that talk about the limiter without exercising it: this ratchet itself
  # and the support module it guards. Named individually — a wildcard here would
  # be a hole big enough to hide a real test in.
  @not_exercising [
    "test/barkpark/rate_limiter_async_isolation_test.exs",
    # A grep over `lib/` for unscoped `check/2` call sites. It never opens a
    # bucket, so it needs no reset and is safe to run concurrently.
    "test/barkpark/rate_limiter_scoped_key_coverage_test.exs",
    "test/support/rate_limiter_sandbox.ex"
  ]

  describe "the contamination is real, and the reset removes it" do
    test "a spent bucket survives into the next test unless something clears it" do
      key = {:token, "isolation-probe"}

      # Spend the single token this key has.
      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :ok
      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :rate_limited

      # WITHOUT a reset the bucket is still empty — this is the leak, asserted
      # rather than described. Any later test using this literal key would open
      # with :rate_limited instead of :ok.
      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :rate_limited

      # WITH the reset it is unspent again, which is exactly what setup gives
      # every test in the files below.
      RateLimiterSandbox.reset!()
      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :ok
    end

    test "reset! empties the named table rather than only the key under test" do
      for i <- 1..5 do
        assert RateLimiter.check({:token, "bulk-#{i}"}, capacity: 5, refill_per_sec: 0.0) == :ok
      end

      assert :ets.info(RateLimiterSandbox.table(), :size) >= 5

      RateLimiterSandbox.reset!()
      assert :ets.info(RateLimiterSandbox.table(), :size) == 0
    end

    test "reset_rate_limiter!/1 REFUSES to wipe shared node state for an async test" do
      # The guard that stops this fix from becoming a new flake: an async test
      # clearing a :named_table would wipe its concurrently-running peers.
      assert_raise RuntimeError, ~r/async: true/, fn ->
        RateLimiterSandbox.reset_rate_limiter!(%{async: true, module: __MODULE__})
      end
    end
  end

  describe "every limiter-touching test file is isolated" do
    test "the scan finds the known files (anti-vacuity)" do
      files = limiter_test_files()

      assert "test/barkpark/rate_limiter_test.exs" in files,
             "the scanner missed the limiter's own test file — it is looking in the " <>
               "wrong place (#{@test_root}) or the marks no longer match"

      assert length(files) >= 10,
             "expected the known cluster of limiter-touching files, found #{length(files)}"
    end

    test "each is async: false — the reset is only safe with no concurrent peer" do
      offenders =
        for path <- limiter_test_files(),
            source = read!(path),
            not (source =~ ~r/async:\s*false/),
            do: path

      assert offenders == [],
             """
             These test files touch Barkpark.RateLimiter but are not `async: false`:

               #{Enum.join(offenders, "\n  ")}

             `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state. Two async
             tests exercising it run concurrently and spend each other's buckets, and
             the per-test reset cannot help: clearing the table under a live peer is a
             worse bug than the one it fixes.

             Keep limiter tests `async: false`, or give the limiter a per-test table
             seam so they can genuinely be isolated.
             """
    end

    test "each actually calls the reset" do
      missing =
        for path <- limiter_test_files(),
            source = read!(path),
            not String.contains?(source, "reset_rate_limiter!"),
            do: path

      assert missing == [],
             """
             These test files touch Barkpark.RateLimiter but never reset it:

               #{Enum.join(missing, "\n  ")}

             Add, just below the `use` line:

                 import Barkpark.RateLimiterSandbox
                 setup :reset_rate_limiter!

             Without it the test inherits whatever buckets earlier files spent, and
             its result depends on the run order.
             """
    end
  end

  # ── derivation ─────────────────────────────────────────────────────────────

  # Every test-tree file that names the limiter or its table, minus the files
  # that only talk ABOUT it.
  defp limiter_test_files do
    @test_root
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      source = File.read!(path)

      String.contains?(source, "RateLimiter") or
        String.contains?(source, "barkpark_rate_limiter")
    end)
    |> Enum.map(&relative/1)
    |> Enum.reject(&(&1 in @not_exercising))
    |> Enum.sort()
  end

  defp relative(path) do
    root = Path.expand("../..", __DIR__)
    "test/" <> Path.relative_to(path, Path.join(root, "test"))
  end

  defp read!(relative_path) do
    Path.expand("../..", __DIR__) |> Path.join(relative_path) |> File.read!()
  end
end
