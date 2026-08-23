defmodule Barkpark.RateLimiterConcurrencyTest do
  @moduledoc """
  The token-bucket debit under contention — the property the limiter exists for.

  THE DEFECT THIS PINS (origin/main 122fd0df81, `check/2`): the bucket was read
  with `:ets.lookup/2` and written back with an unconditional `:ets.insert/2`.
  Two separate atomic operations are not one atomic operation. With the bucket
  at `{k, 1.0, t}`: process A looks up and reads `1.0`; process B looks up
  BEFORE A inserts and reads the same `1.0`; A computes `refilled = 1.0`, passes
  `>= 1.0`, inserts `{k, 0.0, now}` and returns `:ok`; B computes `1.0` from its
  now-stale read, passes the same test, inserts `{k, 0.0, now}` and also returns
  `:ok`. Two admissions, one token debited. At N-way contention on one key, up
  to N-1 extra admissions — the bound fails OPEN under exactly the concurrency
  it exists to bound. The empty-bucket branch was a second, separate race: N
  callers could all read `[]` and each `:ets.insert` a FULL bucket, so every one
  of them reset the bucket and was admitted.

  The fix commits both branches conditionally on the state that was read
  (`:ets.select_replace/2` pinning the exact tuple, `:ets.insert_new/2` for the
  cold key) and retries from a fresh read on a lost race.

  MAKE-THE-CHECK-ABLE-TO-FAIL. A suite that only asserts the FIXED limiter
  admits exactly capacity is vacuous, because at one scheduler the unfixed body
  passes that assertion too. So this file carries two twins of the origin/main
  body over their own private tables:

    * `LegacyTwinYield` — the origin/main body plus ONE `:erlang.yield()` at the
      read-to-write seam and nothing else. Asserted, per round, to over-admit.
    * `LegacyTwinVerbatim` — the body byte-verbatim. NOT asserted; its per-round
      distribution is PRINTED beside `:erlang.system_info(:schedulers_online)`.

  Why the split: the verbatim body never over-admits at one scheduler and is
  flaky at two, and `.github/workflows/elixir.yml` pins no `+S` and no
  `--max-cases`, so CI's scheduler count is unknown. A per-round assertion on
  the verbatim twin would be permanently red on a 1-vCPU runner. The yield
  WIDENS the seam; it does not create the race — the same body over-admits
  without it whenever two schedulers actually interleave there, which is what
  the printed distribution reports.
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias Barkpark.RateLimiter

  # async: false is mandatory: `rate_limiter_test.exs` and friends
  # `:ets.delete_all_objects/1` the process-global `:barkpark_rate_limiter`
  # table in setup, so a concurrent run would corrupt this file and be
  # corrupted by it.

  @rounds 20
  @capacity 50
  @contenders 200
  @table_opts [:set, :public, read_concurrency: true, write_concurrency: true]

  # LIVENESS ONLY, never the property under test: `race/2` hands the scheduler
  # @contenders busy-spinning processes and then has to drain 2N messages, so on
  # a 1-vCPU runner the parent competes with 200 spinners for one scheduler.
  # Measured at `+S 1` the whole file finishes in 0.5s, but a starved runner
  # must red on an ASSERTION, never on a receive timeout — a timeout here would
  # read as "the limiter over-admitted" when nothing of the sort happened.
  @barrier_timeout_ms 60_000

  defmodule LegacyTwinVerbatim do
    @moduledoc false
    # The origin/main `check/2` body, byte-verbatim apart from taking its table
    # as an argument (the shared named table belongs to the real limiter) and
    # dropping the `maybe_prune/1` call, which is a no-op below @max_entries and
    # touches nothing this file measures.
    def check(table, key, capacity, refill) do
      now_ms = System.monotonic_time(:millisecond)

      case :ets.lookup(table, key) do
        [] ->
          :ets.insert(table, {key, capacity - 1.0, now_ms})
          :ok

        [{^key, tokens, last_ms}] ->
          elapsed_s = (now_ms - last_ms) / 1000
          refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

          if refilled >= 1.0 do
            :ets.insert(table, {key, refilled - 1.0, now_ms})
            :ok
          else
            :rate_limited
          end
      end
    end
  end

  defmodule LegacyTwinYield do
    @moduledoc false
    # LegacyTwinVerbatim plus ONE `:erlang.yield()` between the read and the
    # decision-and-write. Nothing else differs: the arithmetic is identical and
    # the writes are the same unconditional `:ets.insert/2`.
    #
    # The yield WIDENS the read-to-write seam so the interleaving is observed on
    # every run and at every scheduler count. It does not CREATE the race: the
    # seam is already there in the verbatim body, and the verbatim twin lands in
    # it whenever the runtime happens to preempt there.
    def check(table, key, capacity, refill) do
      now_ms = System.monotonic_time(:millisecond)
      read = :ets.lookup(table, key)

      :erlang.yield()

      case read do
        [] ->
          :ets.insert(table, {key, capacity - 1.0, now_ms})
          :ok

        [{^key, tokens, last_ms}] ->
          elapsed_s = (now_ms - last_ms) / 1000
          refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

          if refilled >= 1.0 do
            :ets.insert(table, {key, refilled - 1.0, now_ms})
            :ok
          else
            :rate_limited
          end
      end
    end
  end

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    :ok
  end

  describe "the guard is able to fail" do
    test "the seam-widened twin over-admits in every round" do
      table = :ets.new(:legacy_twin_yield, @table_opts)

      admitted_per_round =
        for round <- 1..@rounds do
          key = {:twin_yield, round}

          admitted =
            race(@contenders, fn ->
              LegacyTwinYield.check(table, key, @capacity, 0.0)
            end)

          assert admitted > @capacity,
                 "round #{round}: the unfixed body admitted #{admitted} of #{@contenders} " <>
                   "at capacity #{@capacity} — expected it to OVER-admit, so this guard " <>
                   "would not have been able to fail"

          admitted
        end

      assert length(admitted_per_round) == @rounds
    end

    test "the byte-verbatim twin reports its distribution rather than asserting" do
      table = :ets.new(:legacy_twin_verbatim, @table_opts)

      admitted_per_round =
        for round <- 1..@rounds do
          key = {:twin_verbatim, round}

          race(@contenders, fn ->
            LegacyTwinVerbatim.check(table, key, @capacity, 0.0)
          end)
        end

      over = Enum.count(admitted_per_round, &(&1 > @capacity))

      IO.puts("""

      [rate_limiter_concurrency] byte-verbatim origin/main twin, REPORTED not asserted
        schedulers_online: #{:erlang.system_info(:schedulers_online)}
        capacity: #{@capacity}  contenders: #{@contenders}  rounds: #{@rounds}
        admitted per round: [#{Enum.map_join(admitted_per_round, ", ", &Integer.to_string/1)}]
        rounds that over-admitted: #{over}/#{@rounds}
      """)

      # Deliberately no assertion: at one scheduler this body does not land in
      # its own seam, and CI pins no scheduler count.
      assert length(admitted_per_round) == @rounds
    end
  end

  describe "the patched limiter under contention" do
    test "admits exactly capacity in every round" do
      for round <- 1..@rounds do
        key = {:cas_exact, round}

        admitted =
          race(@contenders, fn ->
            RateLimiter.check(key, capacity: @capacity, refill_per_sec: 0.0)
          end)

        assert admitted == @capacity,
               "round #{round}: admitted #{admitted} of #{@contenders} at capacity #{@capacity}"
      end
    end

    test "never UNDER-admits — the retry budget denies no legitimate caller" do
      # The fail-closed retry budget is new surface: an exhausted budget returns
      # :rate_limited, so a too-small bound would silently deny traffic the
      # unfixed limiter admitted. Widths and capacities are varied so a bound
      # that is merely lucky at one shape shows up here.
      for {capacity, contenders} <- [{1, 200}, {10, 200}, {50, 200}, {199, 200}, {200, 200}] do
        key = {:cas_no_under, capacity, contenders}

        admitted =
          race(contenders, fn ->
            RateLimiter.check(key, capacity: capacity, refill_per_sec: 0.0)
          end)

        refute admitted < capacity,
               "capacity #{capacity} / #{contenders} contenders: admitted only #{admitted} — " <>
                 "the commit-retry budget denied a caller that held a token"

        assert admitted == capacity
      end
    end

    test "the cold-key race admits exactly capacity and leaves a DEPLETED bucket" do
      # The unconditional insert on the empty branch let every racing caller
      # create a FULL bucket. With insert_new/2 exactly one creates it and the
      # losers fall through to the existing-bucket branch and debit it, so the
      # bucket must end BELOW one token rather than near capacity.
      for round <- 1..@rounds do
        key = {:cas_cold, round}
        capacity = 5

        admitted =
          race(50, fn ->
            RateLimiter.check(key, capacity: capacity, refill_per_sec: 0.0)
          end)

        assert admitted == capacity, "round #{round}: cold-key race admitted #{admitted}"

        [{^key, tokens, _last_ms}] = :ets.lookup(:barkpark_rate_limiter, key)

        assert tokens < 1.0,
               "round #{round}: bucket left holding #{tokens} tokens — a loser of the " <>
                 "insert_new race re-created a full bucket instead of debiting the existing one"
      end
    end
  end

  describe "the compare-and-swap match spec" do
    # STRUCTURAL, not behavioural: a `:"$1"`-key head with an equality guard
    # replaces the same row and returns the same 1, so no behavioural probe can
    # tell it from the pinned head — while costing a full table scan per call.
    test "pins the literal key term rather than a match variable, for tuple keys" do
      key = {:auth_write, :register, "203.0.113.7"}
      current = {key, 4.0, 123}
      replacement = {key, 3.0, 456}

      assert [{head, guards, body}] = RateLimiter.__cas_spec__(current, replacement)
      assert head == current
      assert elem(head, 0) === key
      refute match_variable?(elem(head, 0))
      assert guards == []
      assert body == [{:const, replacement}]
    end

    test "pins the literal key term rather than a match variable, for string keys" do
      # The shape BarkparkWeb.Plugs.RateLimit builds.
      key = "ip:203.0.113.7"
      current = {key, 9.0, 1}
      replacement = {key, 8.0, 2}

      assert [{head, guards, body}] = RateLimiter.__cas_spec__(current, replacement)
      assert elem(head, 0) === key
      refute match_variable?(elem(head, 0))
      assert guards == []
      assert body == [{:const, replacement}]
    end

    test "the spec actually replaces only the pinned tuple" do
      table = :ets.new(:cas_spec_probe, @table_opts)
      key = {:ticket, "k1", :read}
      :ets.insert(table, {key, 4.0, 100})

      # A stale `current` must lose.
      stale = {key, 9.0, 100}
      assert :ets.select_replace(table, RateLimiter.__cas_spec__(stale, {key, 8.0, 101})) == 0
      assert :ets.lookup(table, key) == [{key, 4.0, 100}]

      # The exact tuple must win.
      assert :ets.select_replace(
               table,
               RateLimiter.__cas_spec__({key, 4.0, 100}, {key, 3.0, 101})
             ) == 1

      assert :ets.lookup(table, key) == [{key, 3.0, 101}]
    end
  end

  describe "sequential semantics are preserved" do
    test "a scripted timeline drives the twin and the patched limiter identically" do
      script = [
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:sleep, 60},
        # 60ms at 100 tokens/s refills past capacity, so the bucket caps at 3;
        # every later check uses refill 0.0 so elapsed time cannot drift the
        # expected sequence between the two runs.
        {:check, 3, 100.0},
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:check, 3, 0.0},
        {:sleep, 60},
        {:check, 3, 0.0}
      ]

      table = :ets.new(:legacy_twin_sequential, @table_opts)
      twin_key = {:seq_twin, 1}
      real_key = {:seq_real, 1}

      twin =
        Enum.flat_map(script, fn
          {:sleep, ms} ->
            :timer.sleep(ms)
            []

          {:check, capacity, refill} ->
            [LegacyTwinVerbatim.check(table, twin_key, capacity, refill)]
        end)

      real =
        Enum.flat_map(script, fn
          {:sleep, ms} ->
            :timer.sleep(ms)
            []

          {:check, capacity, refill} ->
            [RateLimiter.check(real_key, capacity: capacity, refill_per_sec: refill)]
        end)

      assert real == twin

      assert real == [
               :ok,
               :ok,
               :ok,
               :rate_limited,
               :rate_limited,
               :ok,
               :ok,
               :ok,
               :rate_limited,
               :rate_limited
             ]
    end
  end

  # Every caller is spawned BEFORE the release and spins on a shared :atomics
  # flag, so all N are runnable at the same instant. A sequential `send/2` loop
  # or a bare Task.async_stream staggers the callers and is near-vacuous: the
  # first caller finishes its whole read-modify-write before the last is even
  # started, and the seam is never entered twice.
  defp race(n, fun) do
    gate = :atomics.new(1, signed: false)
    parent = self()

    for _ <- 1..n do
      spawn_link(fn ->
        send(parent, {:ready, self()})
        spin(gate)
        send(parent, {:result, fun.()})
      end)
    end

    for _ <- 1..n, do: assert_receive({:ready, _}, @barrier_timeout_ms)

    :atomics.put(gate, 1, 1)

    results =
      for _ <- 1..n do
        assert_receive({:result, result}, @barrier_timeout_ms)
        result
      end

    Enum.count(results, &(&1 == :ok))
  end

  defp spin(gate) do
    if :atomics.get(gate, 1) == 1, do: :ok, else: spin(gate)
  end

  defp match_variable?(term) when is_atom(term),
    do: String.starts_with?(Atom.to_string(term), "$")

  defp match_variable?(_), do: false
end
