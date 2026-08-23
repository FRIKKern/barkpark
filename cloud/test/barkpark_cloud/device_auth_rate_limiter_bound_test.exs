defmodule BarkparkCloud.DeviceAuthRateLimiterBoundTest do
  @moduledoc """
  acpc-bl-poll-key-unbounded-ets-growth — the limiter's table had no bound.

  The per-key sweep in `check/1` pins the key being checked, so it only ever
  reaps THAT key's elapsed rows. It bounds a key that RECURS. The `"poll:"`
  bucket does not recur: `router.ex`'s `POST /v1/auth/device/poll` calls
  `check("poll:" <> DeviceAuth.device_code_hash(device_code))` BEFORE
  `DeviceAuth.poll/1` validates the code, and `device_code_hash/1` is
  `UserToken.hash_token/1` — a pure hash of caller bytes. So every distinct
  `device_code` an unauthenticated caller posts minted a row nothing ever swept.

  These tests pin the MECHANISM (one-shot keys accrete under the per-key sweep
  alone), the BOUND (a global sweep reclaims them), and the two properties that
  make the bound safe to run in-band: it must not reset a live counter, and it
  must not make every caller pay a scan.

  `async: false` — the limiter is a singleton with one public named ETS table.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.DeviceAuth
  alias BarkparkCloud.DeviceAuth.RateLimiter

  @table BarkparkCloud.DeviceAuth.RateLimiter
  @window_ms 60_000
  # `check/1` skips the global sweep below this; every test that exercises the
  # sweep must first cross it. Mirrors @prune_floor in the module under test.
  @prune_floor 256

  setup do
    RateLimiter.reset()
    TwoFactorRateLimiter.reset()
    on_exit(fn -> RateLimiter.reset() end)
    :ok
  end

  defp size, do: :ets.info(@table, :size)

  # One-shot attacker-shaped keys: a distinct hash per call, exactly what a
  # caller posting random device_codes produces at the poll route.
  defp mint(n, now_ms) do
    for i <- 1..n do
      key = "poll:" <> DeviceAuth.device_code_hash("device-code-#{i}-#{System.unique_integer()}")
      :ok = RateLimiter.check(key, now_ms)
      key
    end
  end

  describe "the mechanism" do
    test "one-shot keys accrete: the per-key sweep never reaps a key that does not return" do
      now = @window_ms * 1_000
      n = @prune_floor - 1

      mint(n, now)

      assert size() == n,
             "each one-shot key holds its own row; nothing has swept them"

      # Advancing the window does NOT reclaim them on its own — that is the whole
      # defect. Only a check for a GIVEN key sweeps that key, and these never
      # return. One new key in the next window sweeps only itself.
      mint(1, now + @window_ms)

      assert size() == n + 1,
             "a later window's traffic does not reclaim an earlier window's dead keys"
    end
  end

  describe "the bound" do
    test "a global sweep reclaims every elapsed key once the window turns" do
      now = @window_ms * 2_000
      n = @prune_floor + 200

      mint(n, now)

      assert size() == n + 1,
             "n key rows plus this window's single claim marker"

      # One call in the NEXT window elects itself to sweep and reaps all of them.
      mint(1, now + @window_ms)

      assert size() <= 2,
             "the new key plus this window's prune marker; every elapsed row is gone " <>
               "(held #{size()})"
    end

    test "a STALE-window caller's sweep cannot reset a live counter and refill its budget" do
      # THE STRICTNESS PROOF. The global sweep deletes STRICTLY EARLIER windows,
      # never merely DIFFERENT ones — the same reason the per-key sweep above it
      # is `<` and not `/=`. A caller whose `window` view is behind (a backwards
      # clock step, or simply the scheduling gap since it derived `now_ms`) would
      # otherwise sweep every row that is not ITS window, deleting counters in
      # the CURRENT window and handing those callers their full budget back —
      # turning the memory bound into a rate-limit bypass.
      #
      # Note this is NOT provable by a same-window caller: with `/=` a sweeper at
      # window W leaves W's rows alone, so the mutation is invisible unless the
      # sweeper is actually behind. Hence the explicit backwards step.
      now = @window_ms * 3_000
      earlier = now - @window_ms

      victim = "poll:live-counter"
      for _ <- 1..20, do: :ok = RateLimiter.check(victim, now)

      assert {:error, :rate_limited} = RateLimiter.check(victim, now),
             "the victim starts out of budget in the CURRENT window"

      # A caller arrives with a stale view, carrying enough traffic to arm the
      # sweep in the EARLIER window.
      mint(@prune_floor + 10, earlier)

      assert {:error, :rate_limited} = RateLimiter.check(victim, now),
             "a sweep from an earlier window must not delete the CURRENT window's " <>
               "counter — doing so hands this caller its 20-request budget back"
    end

    test "at most ONE caller per window pays the scan" do
      now = @window_ms * 4_000
      mint(@prune_floor + 50, now)

      # The claim marker for this window is present exactly once...
      markers = :ets.select(@table, [{{{:__prune__, :"$1"}, :_}, [], [:"$1"]}])
      assert markers == [div(now, @window_ms)], "one claim, this window (got #{inspect(markers)})"

      # ...and the next window's traffic takes exactly one new claim, while the
      # previous window's marker is reaped by the sweep it authorised.
      mint(@prune_floor + 50, now + @window_ms)

      markers = :ets.select(@table, [{{{:__prune__, :"$1"}, :_}, [], [:"$1"]}])

      assert markers == [div(now + @window_ms, @window_ms)],
             "the marker is self-cleaning: it matches the sweep's own match head"
    end

    test "the marker cannot collide with a real key" do
      # Real keys are always binaries (the router builds them by concatenation);
      # the marker's first element is an ATOM, so the two key spaces are disjoint
      # by type and no caller can forge a claim to suppress the sweep.
      now = @window_ms * 5_000
      mint(@prune_floor + 5, now)

      real = :ets.select(@table, [{{{:"$1", :_}, :_}, [{:is_binary, :"$1"}], [true]}])
      atoms = :ets.select(@table, [{{{:"$1", :_}, :_}, [{:is_atom, :"$1"}], [:"$1"]}])

      assert length(real) == @prune_floor + 5
      assert atoms == [:__prune__]
    end
  end

  describe "the cost, measured rather than assumed" do
    test "bytes per row is measured against the recorded 152.0 figure" do
      now = @window_ms * 6_000
      RateLimiter.reset()

      empty_words = :ets.info(@table, :memory)
      n = 2_000
      mint(n, now)
      full_words = :ets.info(@table, :memory)

      word = :erlang.system_info(:wordsize)
      bytes_per_row = (full_words - empty_words) * word / n

      # The row recorded 152.0 bytes/row. Assert the ORDER, not the exact
      # numeral: the figure is architecture- and OTP-dependent (it is derived
      # from :ets.info(:memory), which counts words), so pinning it exactly would
      # make this a portability tripwire rather than a cost check.
      assert bytes_per_row > 50 and bytes_per_row < 500,
             "measured #{Float.round(bytes_per_row, 1)} bytes/row against the recorded 152.0"

      # The bound, stated in the units an operator cares about: what the table
      # costs at the recorded 1000 req/s attack rate for one window.
      per_window_rows = 1000 * div(@window_ms, 1000)
      mb = per_window_rows * bytes_per_row / 1_048_576

      assert mb < 64,
             "one window of a 1000 req/s flood must fit in tens of MB, not the " <>
               "13 GB/day the unbounded table accrued (computed #{Float.round(mb, 1)} MB)"
    end
  end

  describe "the class: the sibling limiter takes the same fix" do
    test "TwoFactorRateLimiter also reclaims elapsed rows for users who never return" do
      now = @window_ms * 7_000
      table = BarkparkCloud.Accounts.TwoFactorRateLimiter

      for i <- 1..(@prune_floor + 100) do
        :ok = TwoFactorRateLimiter.check("user-#{i}-#{System.unique_integer()}", now)
      end

      assert :ets.info(table, :size) == @prune_floor + 100 + 1,
             "one row per user plus this window's claim marker"

      :ok = TwoFactorRateLimiter.check("user-next-window", now + @window_ms)

      assert :ets.info(table, :size) <= 2,
             "the same defect at a smaller key space takes the same fix, not a wait " <>
               "(held #{:ets.info(table, :size)})"
    end
  end
end
