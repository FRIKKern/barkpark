defmodule BarkparkCloud.TotpTestHelperTest do
  @moduledoc """
  THE CLOUD-SIDE TOTP RATCHET, and the proof the helper is a no-op under
  headroom.

  The wave-1 ratchet (`api/test/barkpark/totp_test_helper_test.exs`) scans
  `Path.wildcard` rooted at `api/test`, and the slice gate greps the same root.
  `cloud/` is a separate app with its own test tree, so NEITHER could ever see a
  raw generator here — charter D6's directory-scope gap, in its mirror image.
  Re-measured at build time (the task recorded 16, which had rotted):
  **23 raw sites across 5 files**, 10 of them off-period.

  This file closes the cloud half. Together with the api file, the ratchet
  covers both trees.
  """
  use ExUnit.Case, async: true

  import BarkparkCloud.TotpTestHelper

  alias BarkparkCloud.TotpTestHelper

  describe "the boundary arithmetic" do
    test "headroom_ms/1 is the distance to the end of the containing period" do
      period_ms = TotpTestHelper.period_seconds() * 1_000

      assert headroom_ms(0) == period_ms
      assert headroom_ms(period_ms) == period_ms
      assert headroom_ms(period_ms + 1) == period_ms - 1
      assert headroom_ms(period_ms * 7 - 1) == 1
    end

    test "wait_ms/2 fires on exactly the thin tail of the period, and nowhere else" do
      period_ms = TotpTestHelper.period_seconds() * 1_000
      min = TotpTestHelper.default_min_headroom_ms()

      # THE NO-OP PROPERTY, AS AN ASSERTION RATHER THAN A COMMENT (criterion 1).
      # Sweep every millisecond offset in a period and pin the exact firing set:
      # a helper that always slept would show 30000 here, not 1999.
      firing = for off <- 0..(period_ms - 1), wait_ms(off, min) > 0, do: off

      assert firing == Enum.to_list((period_ms - min + 1)..(period_ms - 1))
      assert length(firing) == min - 1

      quiet = period_ms - length(firing)
      assert quiet / period_ms > 0.93, "the helper must be a no-op on the vast majority of calls"

      assert wait_ms(0, min) == 0
      assert wait_ms(period_ms - min, min) == 0
    end

    test "sleeping wait_ms/2 lands on the first instant of the next period" do
      period_ms = TotpTestHelper.period_seconds() * 1_000
      min = TotpTestHelper.default_min_headroom_ms()

      for offset <- [period_ms - 1, period_ms - min + 1, period_ms - div(min, 2)] do
        slept = wait_ms(offset, min)
        assert slept > 0
        assert rem(offset + slept, period_ms) == 0
        assert headroom_ms(offset + slept) == period_ms
      end
    end
  end

  describe "the generators" do
    test "await_period_headroom!/1 burns nothing when headroom is ample" do
      # min_headroom_ms: 1 can only fire in the final millisecond of a period, so
      # this is a no-op on all but ~1/30000 runs; assert the returned 0 rather
      # than wall-clock, which is what makes it deterministic.
      assert await_period_headroom!(min_headroom_ms: 1) in [0, 1]
    end

    test "totp_code_stable!/2 produces a code the server would accept now" do
      secret = NimbleTOTP.secret()
      code = totp_code_stable!(secret)

      assert byte_size(code) == 6
      assert NimbleTOTP.valid?(secret, code)
    end

    test "code_for_period_offset!/3 produces a genuinely off-period code" do
      secret = NimbleTOTP.secret()

      previous = code_for_period_offset!(secret, -1)
      current = totp_code_stable!(secret)

      assert previous != current
      refute NimbleTOTP.valid?(secret, previous)
      assert NimbleTOTP.valid?(secret, current)
    end

    test "code_at_period_offset/3 is pure: one base, many offsets, no clock read" do
      secret = NimbleTOTP.secret()
      base = stable_period_base!()

      # The whole point of the base-pinned pair: the SAME base always yields the
      # SAME code, so a group of offsets cannot drift apart mid-test.
      assert code_at_period_offset(secret, base, 0) == code_at_period_offset(secret, base, 0)

      assert code_at_period_offset(secret, base, 0) != code_at_period_offset(secret, base, 1)
      assert code_at_period_offset(secret, base, 0) != code_at_period_offset(secret, base, -1)

      # And an offset of N periods really is N periods away.
      assert code_at_period_offset(secret, base, 1) ==
               code_at_period_offset(secret, base + TotpTestHelper.period_seconds(), 0)
    end
  end

  describe "CONTRACT PARITY with the api helper" do
    # cloud/ cannot depend on api/test/support, so the contract is duplicated on
    # purpose. This is what stops the duplicate drifting: the api module's
    # exported contract must remain a SUBSET of cloud's. Cloud is allowed the two
    # extra base-pinned functions (api has no test of that shape); losing a
    # shared function on either side reds.
    @api_helper Path.expand("../../../api/test/support/totp_test_helper.ex", __DIR__)

    test "every function the api helper exports also exists here, with the same arity" do
      assert File.exists?(@api_helper),
             "could not find the api helper at #{@api_helper} — the parity check is " <>
               "passing vacuously and the two helpers can now drift"

      api_funs = public_funs(File.read!(@api_helper))

      assert MapSet.size(api_funs) >= 9,
             "parsed only #{MapSet.size(api_funs)} public functions out of the api helper — " <>
               "the parser is broken, not the contract"

      cloud_funs =
        TotpTestHelper.__info__(:functions)
        |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
        |> MapSet.new()

      missing = MapSet.difference(api_funs, cloud_funs)

      assert MapSet.size(missing) == 0,
             """
             The cloud TOTP helper is missing part of the api helper's contract:

               #{missing |> Enum.sort() |> Enum.join("\n  ")}

             The two are deliberate twins (cloud cannot load api/test/support). If
             the api side gained a function, add it here too — or the two trees
             stop meaning the same thing by the same name.
             """
    end

    # Public heads, with default args expanded to every callable arity.
    #
    # BOTH SPELLINGS, and the second one is not hypothetical: an earlier draft
    # matched only `def name(...)`, so the api helper's parenless zero-arity
    # heads (`def period_seconds, do: …`) were never in the compared set at all.
    # Renaming one in the cloud twin left this test GREEN — the parity check was
    # decoration over exactly the functions most likely to be dropped. Caught by
    # mutation; the arity-0 branch below is the fix.
    defp public_funs(source) do
      with_parens =
        Regex.scan(~r/^\s*def\s+([a-z_][A-Za-z0-9_!?]*)\(([^)]*)\)/m, source)
        |> Enum.flat_map(fn [_, name, args] ->
          args = String.trim(args)
          total = if args == "", do: 0, else: length(String.split(args, ","))
          defaults = length(Regex.scan(~r/\\\\/, args))
          for a <- (total - defaults)..total, do: "#{name}/#{a}"
        end)

      parenless =
        Regex.scan(~r/^\s*def\s+([a-z_][A-Za-z0-9_!?]*)\s*(?:,\s*do:|do\b)/m, source)
        |> Enum.map(fn [_, name] -> "#{name}/0" end)

      MapSet.new(with_parens ++ parenless)
    end
  end

  describe "THE RATCHET" do
    # Built by concatenation ON PURPOSE: a literal here would flag this very file
    # and the ratchet could never be green.
    @banned "NimbleTOTP." <> "verification_code"

    # `cloud/test` — this file lives at cloud/test/barkpark_cloud/.
    @test_root Path.expand("..", __DIR__)

    # The ONE module allowed to call the raw generator. A single file, not the
    # whole support/ directory: a second raw producer anywhere is the population
    # regrowing.
    @helper_source Path.join(@test_root, "support/totp_test_helper.ex")

    test "the raw TOTP generator appears nowhere under cloud/test/ except the helper" do
      scanned =
        @test_root
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()

      # ANTI-VACUITY. A wrong root makes Path.wildcard/1 return [] and the
      # ratchet passes having measured NOTHING.
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

                 import BarkparkCloud.TotpTestHelper
                 code = totp_code_stable!(secret)

             Need an off-period code (to probe the acceptance WINDOW)? Use
             `code_for_period_offset!/3`. Need several offsets pinned to ONE
             instant? `stable_period_base!/1` + `code_at_period_offset/3`.
             """
    end
  end
end
