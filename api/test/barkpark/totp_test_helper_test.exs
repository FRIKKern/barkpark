defmodule Barkpark.TotpTestHelperTest do
  @moduledoc """
  The helper's own tests, plus THE RATCHET (honest-gates charter, part three).

  A fix without a ratchet regrows. This file is the tripwire that keeps the raw
  TOTP generator out of `api/test/` for good, and the proof that the helper is
  a targeted boundary wait rather than a blanket sleep — because "I added a
  sleep and the flake went away" is the failure mode one step down from the one
  being fixed here.
  """
  use ExUnit.Case, async: true

  import Barkpark.TotpTestHelper

  describe "boundary arithmetic (pure — no wall clock involved)" do
    test "headroom_ms is a full period at a period start and 1ms at its last millisecond" do
      period_ms = period_seconds() * 1_000

      assert headroom_ms(0) == period_ms
      assert headroom_ms(period_ms) == period_ms
      assert headroom_ms(period_ms + 1) == period_ms - 1
      assert headroom_ms(period_ms * 7 - 1) == 1
    end

    test "the wait NEVER fires under headroom — it fires on exactly the last min_headroom-1 ms" do
      # This is the criterion that separates a targeted boundary wait from a
      # blanket sleep. Sweeping the WHOLE period pins the firing set exactly,
      # so a future 'simplification' to `Process.sleep(period)` cannot pass.
      period_ms = period_seconds() * 1_000
      min = default_min_headroom_ms()

      firing = for offset <- 0..(period_ms - 1), wait_ms(offset, min) > 0, do: offset

      assert firing == Enum.to_list((period_ms - min + 1)..(period_ms - 1))
      assert length(firing) == min - 1

      # …and it is a no-op across the other 93.3% of the period.
      quiet = Enum.count(0..(period_ms - 1), &(wait_ms(&1, min) == 0))
      assert quiet == period_ms - length(firing)
      assert quiet / period_ms > 0.93
      assert wait_ms(0, min) == 0
      assert wait_ms(period_ms - min, min) == 0
    end

    test "when it does fire it sleeps exactly to the next period start — maximum headroom" do
      period_ms = period_seconds() * 1_000
      min = default_min_headroom_ms()

      for offset <- [period_ms - 1, period_ms - min + 1, period_ms - min + 500] do
        slept = wait_ms(offset, min)
        assert slept > 0
        # Landing point is the first instant of the next period, so the wait is
        # needed at most once. A wait that lands mid-period would need a retry
        # loop, and a retry loop is not a fix.
        assert rem(offset + slept, period_ms) == 0
        assert headroom_ms(offset + slept) == period_ms
      end
    end
  end

  describe "against the real clock" do
    test "await_period_headroom! is a NO-OP (0ms slept) once headroom exists" do
      # First call guarantees at least `default_min_headroom_ms` remains.
      _ = await_period_headroom!()

      # A second call asking for HALF that budget therefore cannot need to wait.
      {elapsed_us, slept_ms} =
        :timer.tc(fn ->
          await_period_headroom!(min_headroom_ms: div(default_min_headroom_ms(), 2))
        end)

      assert slept_ms == 0
      assert elapsed_us < 50_000, "helper burned #{elapsed_us}us under ample headroom"
    end

    test "totp_code_stable! produces a code valid for the CURRENT period" do
      secret = NimbleTOTP.secret()
      code = totp_code_stable!(secret)

      assert byte_size(code) == 6
      assert NimbleTOTP.valid?(secret, code)
    end

    test "code_for_period_offset! produces off-period codes the current period rejects" do
      # The api suite generated ZERO off-period codes before this slice, which
      # is precisely why it could not see the TOTP acceptance window widen.
      secret = NimbleTOTP.secret()

      previous = code_for_period_offset!(secret, -1)
      current = totp_code_stable!(secret)

      assert previous != current
      refute NimbleTOTP.valid?(secret, previous)
      assert NimbleTOTP.valid?(secret, current)
    end
  end

  describe "THE RATCHET" do
    # Built by concatenation ON PURPOSE: if this file contained the banned call
    # as a literal, the scan below would flag itself and the ratchet could never
    # be green. The same trick keeps it out of the shell-side grep in CI.
    @banned "NimbleTOTP." <> "verification_code"

    # `api/test` — this file lives at api/test/barkpark/.
    @test_root Path.expand("..", __DIR__)

    # The ONE module allowed to call the raw generator. Deliberately a single
    # file, not the whole `support/` directory: a second raw producer anywhere,
    # even in support, is the population regrowing.
    @helper_source Path.join(@test_root, "support/totp_test_helper.ex")

    test "the raw TOTP generator appears nowhere under api/test/ except the helper" do
      scanned =
        @test_root
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()

      # ANTI-VACUITY, mirroring the async-env-seam guard's own defence. Without
      # this, a wrong @test_root (a moved file, a renamed directory) makes
      # Path.wildcard/1 return [] and the ratchet passes having measured
      # NOTHING. A guard that cannot fail is the disease, not the cure — so the
      # scan must prove it actually walked the tree before its verdict counts.
      assert length(scanned) > 100,
             "the ratchet scanned only #{length(scanned)} files under #{@test_root} — " <>
               "the root is wrong and this gate is passing vacuously"

      assert @helper_source in scanned,
             "the ratchet did not see the helper it allowlists (#{@helper_source}) — " <>
               "the allowlist is stale and a real offender could be hiding behind it"

      offenders =
        scanned
        |> Enum.reject(&(&1 == @helper_source))
        |> Enum.filter(&String.contains?(File.read!(&1), @banned))
        |> Enum.map(&Path.relative_to(&1, @test_root))
        |> Enum.sort()

      assert offenders == [],
             """
             Raw #{@banned}/1 found outside the window-stable helper:

               #{Enum.join(offenders, "\n  ")}

             A code minted inline expires if the 30s TOTP period rolls before the
             server validates it, and the run then reds for the wall clock rather
             than for the behaviour under test. Use the helper instead:

                 import Barkpark.TotpTestHelper
                 code = totp_code_stable!(secret)

             Need an off-period code (to probe the acceptance WINDOW)? Use
             `code_for_period_offset!/3`, not the raw generator.

             Named a `support/__ratchet_probe_*.exs` file? That is inert debris
             from the able-to-fail test below being killed mid-run (its `after`
             block normally deletes it). Delete it — it is not a real offence,
             and this gate reporting it as one would itself be a lying gate.
             """
    end

    test "the scan is able to fail — a raw call in a scanned file is detected" do
      # Proving the ratchet can go red WITHOUT committing a red: the predicate
      # is run against a temp file inside the scanned tree. A guard that has
      # never been shown to fail is indistinguishable from a guard that cannot.
      planted =
        Path.join(@test_root, "support/__ratchet_probe_#{System.unique_integer([:positive])}.exs")

      try do
        File.write!(planted, "code = #{@banned}(secret)\n")

        detected =
          @test_root
          |> Path.join("**/*.{ex,exs}")
          |> Path.wildcard()
          |> Enum.reject(&(&1 == @helper_source))
          |> Enum.filter(&String.contains?(File.read!(&1), @banned))

        assert planted in detected,
               "the ratchet did not notice a planted raw generator call — it cannot fail"
      after
        File.rm(planted)
      end
    end
  end
end
