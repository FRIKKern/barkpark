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
    # purpose. The api module's exported contract must remain a SUBSET of
    # cloud's. Cloud is allowed the two extra base-pinned functions (api has no
    # test of that shape); losing a shared function on either side reds.
    #
    # SCOPE, STATED HONESTLY: this compares NAMES AND ARITIES ONLY. It is blind
    # to every line of both BODIES — a proven blind spot, not a theoretical one
    # (see the mutation recorded in "BEHAVIOURAL PARITY" below, which this test
    # passed with 0 failures). Keep it: it is the cheap layer, and it catches the
    # drop/rename that a behavioural check would only report as a compile error.
    # But do NOT let it be read as "the twins cannot diverge".
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

  describe "BEHAVIOURAL PARITY with the api helper" do
    # WHY THIS EXISTS, AND WHY THE DESCRIBE ABOVE IS NOT ENOUGH.
    #
    # The CONTRACT PARITY test compares NAMES AND ARITIES. It reads the api
    # source and regex-scans its public `def` heads; it never looks at a single
    # line of either BODY. Mutation, run before this block was written: the api
    # twin's `@period_seconds` was changed 30 -> 60 and `wait_ms/2`'s firing
    # clause was changed to return 0 (so the boundary wait NEVER fires) — i.e.
    # the api twin was turned into the exact wall-clock race both helpers exist
    # to remove, with no signature touched. The file ran `9 tests, 0 failures`,
    # exit 0. The moduledoc's "the duplication cannot drift silently" was true
    # only of the function LIST.
    #
    # So: same names is not same behaviour. This block runs both
    # implementations against the same pinned inputs.
    #
    # HOW, given cloud/ cannot load api/test/support: read the api source AT
    # TEST RUN TIME and compile it into this VM under a shadow module name. The
    # helper depends on nothing but NimbleTOTP (a cloud dep) and stdlib, so it
    # compiles standalone here.
    #
    # ── COMPILE-TIME SAFETY, LOAD-BEARING ──────────────────────────────────
    # cloud/'s Docker build context is cloud/ ONLY — api/ does not exist inside
    # the image. A COMPILE-time read of an api/ path (`File.read!` at module
    # scope, `@external_resource`, or any module attribute that touches the
    # filesystem) would therefore BRICK the cloud image. Every read below
    # happens inside a `test` or `setup_all` body, or in a `defp` called from
    # one. `@api_helper` / `@cloud_helper` are `Path.expand/2` only — pure
    # string math, no filesystem. Keep it that way.
    #
    # (Belt and braces: cloud/mix.exs compiles `test/support` and `test/` in
    # `elixirc_paths(:test)` only, so nothing here is in the release regardless.)
    # ───────────────────────────────────────────────────────────────────────
    @cloud_helper Path.expand("../support/totp_test_helper.ex", __DIR__)
    @api_shadow BarkparkCloud.TotpTestHelperTest.ApiTwin

    setup do
      # `setup`, not `setup_all`: ExUnit forbids setup_all inside a describe.
      # Runs at TEST time, not compile time. Tests within one module run
      # sequentially (async: true parallelises across modules, not inside one)
      # and compile_api_twin!/0 is memoised on the loaded module, so the api
      # source is read and compiled exactly once per run.
      [api: compile_api_twin!()]
    end

    test "the shared constants are the committed literals on BOTH sides", %{api: api} do
      # LITERALS, not a floor computed from either tree: if both helpers were
      # gutted in the same direction, a mutual comparison would still agree.
      # These are the values the servers actually implement.
      assert TotpTestHelper.period_seconds() == 30
      assert TotpTestHelper.default_min_headroom_ms() == 2_000

      assert api.period_seconds() == 30, drift("period_seconds/0 is not 30 on the api side")

      assert api.default_min_headroom_ms() == 2_000,
             drift("default_min_headroom_ms/0 is not 2000 on the api side")
    end

    test "headroom_ms/1 agrees, and matches the committed table", %{api: api} do
      # {now_ms, expected} — hand-computed against a 30_000ms period.
      table = [
        {0, 30_000},
        {1, 29_999},
        {29_999, 1},
        {30_000, 30_000},
        {30_001, 29_999},
        {209_999, 1},
        {1_700_000_000_000, 10_000}
      ]

      for {now_ms, expected} <- table do
        assert TotpTestHelper.headroom_ms(now_ms) == expected
        assert api.headroom_ms(now_ms) == expected, drift("headroom_ms(#{now_ms}) != #{expected}")
      end
    end

    test "wait_ms/2 agrees, and matches the committed table", %{api: api} do
      # {now_ms, min_headroom_ms, expected}
      table = [
        {0, 2_000, 0},
        {28_000, 2_000, 0},
        {28_001, 2_000, 1_999},
        {29_000, 2_000, 1_000},
        {29_999, 2_000, 1},
        {30_000, 2_000, 0},
        {0, 30_000, 0},
        {1, 30_000, 29_999}
      ]

      for {now_ms, min, expected} <- table do
        assert TotpTestHelper.wait_ms(now_ms, min) == expected

        assert api.wait_ms(now_ms, min) == expected,
               drift("wait_ms(#{now_ms}, #{min}) != #{expected}")
      end
    end

    test "the api helper is a no-op on the same 93.3% of the period", %{api: api} do
      # The mirror of the cloud-side sweep, aimed at the api twin. A helper that
      # never waits (or always waits) shows a different count here — this is the
      # assertion that catches "wait_ms was quietly disarmed", which is invisible
      # to a name/arity check and to any comparison of doc comments.
      firing = for off <- 0..29_999, api.wait_ms(off, 2_000) > 0, do: off

      assert length(firing) == 1_999,
             drift(
               "the api helper's wait_ms/2 fires on #{length(firing)} of 30000 offsets, not 1999"
             )

      assert firing == Enum.to_list(28_001..29_999),
             drift("the api helper's wait_ms/2 fires on the wrong offsets")
    end

    # THE COVERAGE FENCE — the reason this block cannot rot into the same shape
    # it was written to replace.
    #
    # The tests above name the functions they exercise, and that naming is done
    # by hand. A hand-written list of what-we-check is exactly the weakness the
    # CONTRACT PARITY test had: it is an ENUMERATED SUBSET, and it goes quiet the
    # moment the api helper grows a function nobody added to it. So the surface
    # that must be covered is derived FROM THE API SOURCE at test time, and every
    # function on it must be either behaviourally compared above or waived here
    # in writing, with a reason.
    #
    # The pass/fail threshold is still a committed literal (these two lists), not
    # a floor computed from the tree — a list generated from the source would
    # agree with a gutted source by construction.
    @behaviourally_compared ~w(
      period_seconds/0
      default_min_headroom_ms/0
      headroom_ms/1
      wait_ms/1
      wait_ms/2
      totp_code_stable!/1
      totp_code_stable!/2
      code_for_period_offset!/2
      code_for_period_offset!/3
      await_period_headroom!/1
    )

    @behaviour_waivers %{
      "await_period_headroom!/0" =>
        "the default-arg head of await_period_headroom!/1, which IS compared. " <>
          "Calling the arity-0 head can sleep up to 2s for no signal the /1 call " <>
          "does not already give."
    }

    test "every function the api helper exports is behaviourally compared, or waived in writing" do
      api_funs = public_funs(File.read!(@api_helper))

      # ANTI-VACUITY: a broken parser returns a small set and this fence passes
      # having demanded coverage of almost nothing.
      assert MapSet.size(api_funs) >= 11,
             "parsed only #{MapSet.size(api_funs)} public functions out of #{@api_helper} — " <>
               "the parser is broken, and this coverage fence is measuring nothing"

      compared = MapSet.new(@behaviourally_compared)
      waived = MapSet.new(Map.keys(@behaviour_waivers))

      # STALENESS, THE OTHER WAY: a name in our lists that the api helper no
      # longer exports means the list is decoration over a function that is gone.
      stale = MapSet.difference(MapSet.union(compared, waived), api_funs)

      assert MapSet.size(stale) == 0,
             """
             These names are claimed as compared/waived but #{@api_helper} no
             longer exports them:

               #{stale |> Enum.sort() |> Enum.join("\n  ")}

             Drop them from @behaviourally_compared / @behaviour_waivers, or the
             lists start describing a contract that does not exist.
             """

      uncovered = MapSet.difference(api_funs, MapSet.union(compared, waived))

      assert MapSet.size(uncovered) == 0,
             """
             #{@api_helper} exports functions whose BEHAVIOUR nothing compares:

               #{uncovered |> Enum.sort() |> Enum.join("\n  ")}

             The CONTRACT PARITY test will happily confirm #{@cloud_helper} has
             functions by these names. That is not the same as confirming they do
             the same thing — the twins can diverge in body with every name still
             matching.

             Add a behavioural comparison for each above, or add an entry to
             @behaviour_waivers saying, in writing, why comparing it buys nothing.
             """
    end

    test "both helpers mint the SAME codes for the same secret", %{api: api} do
      secret = NimbleTOTP.secret()

      # Establish headroom ONCE for the whole group: with >= 3s left in the
      # period, every call below lands in the same period, so any difference is
      # drift and never the wall clock.
      base = stable_period_base!(min_headroom_ms: 3_000)

      # await_period_headroom!/1 must be a NO-OP under headroom on both sides —
      # a twin that sleeps unconditionally is "the same disease wearing a fix's
      # clothes", and it would be invisible to every name-based check.
      assert api.await_period_headroom!(min_headroom_ms: 1) in [0, 1],
             drift("await_period_headroom!/1 slept when the period had ample headroom")

      assert await_period_headroom!(min_headroom_ms: 1) in [0, 1]

      api_now = api.totp_code_stable!(secret)

      assert api_now == totp_code_stable!(secret),
             drift("totp_code_stable!/2 produces different codes for the same secret")

      # An ABSOLUTE oracle as well as a mutual one: NimbleTOTP is the reference
      # implementation both helpers wrap, so this reds even if both sides drift
      # together.
      assert NimbleTOTP.valid?(secret, api_now),
             drift("the api helper minted a code NimbleTOTP does not consider current")

      for offset <- [-2, -1, 0, 1, 2] do
        api_code = api.code_for_period_offset!(secret, offset)

        assert api_code == code_for_period_offset!(secret, offset),
               drift("code_for_period_offset!(secret, #{offset}) differs between the twins")

        # ABSOLUTE oracle again, and deliberately via NimbleTOTP's VALIDATOR
        # rather than its generator: the generator's name is the symbol THE
        # RATCHET below bans outside the helper, and reaching for `apply/3` to
        # slip a banned call past a gate is precisely the move this file exists
        # to refuse. `valid?/3` with a pinned `:time` states the same fact — the
        # code is the one for `offset` periods of 30s from the pinned base — so
        # this reds even if BOTH twins drift the same way.
        assert NimbleTOTP.valid?(secret, api_code, time: base + offset * 30),
               drift(
                 "code_for_period_offset!(secret, #{offset}) is not #{offset} * 30s from the base"
               )
      end
    end

    # Reads and compiles the api twin. Called ONLY from setup/test bodies —
    # never at compile time (see the compile-time safety note above).
    defp compile_api_twin! do
      # Memoised: the shadow module is only ever in memory if WE put it there
      # (it is not on any load path), so this is a per-run "already compiled?".
      if Code.ensure_loaded?(@api_shadow), do: @api_shadow, else: compile_api_twin_now!()
    end

    defp compile_api_twin_now! do
      source =
        case File.read(@api_helper) do
          {:ok, source} ->
            source

          {:error, reason} ->
            flunk("""
            Could not read the api TOTP helper at

              #{@api_helper}

            (#{:file.format_error(reason)})

            #{@cloud_helper} is a hand-typed twin of that module. If the api file
            moved or was renamed, REPOINT this guard — do not delete it, or the
            two helpers can drift again with nothing watching.
            """)
        end

      opening = "defmodule Barkpark.TotpTestHelper do"

      assert String.contains?(source, opening),
             """
             #{@api_helper} no longer opens with `#{opening}`.

             This guard renames that module to compile it into cloud's test VM,
             and the rename just silently no-opped. Repoint it before the check
             goes quiet.
             """

      renamed =
        String.replace(source, opening, "defmodule #{inspect(@api_shadow)} do", global: false)

      compiled =
        try do
          Code.compile_string(renamed, @api_helper)
        rescue
          error ->
            flunk("""
            #{@api_helper} no longer compiles standalone inside cloud's test VM:

              #{Exception.message(error)}

            The behavioural parity guard compiles the api twin here because
            cloud/ is a separate mix project and cannot load api/test/support.
            If the api helper gained a dependency cloud does not have, either add
            it or replace this guard with one that still compares BEHAVIOUR —
            a name/arity check alone lets the twins drift silently.
            """)
        end

      assert [{@api_shadow, _beam}] = compiled,
             "compiling #{@api_helper} produced #{inspect(Enum.map(compiled, &elem(&1, 0)))}, " <>
               "not exactly the shadow twin — the guard is measuring the wrong module"

      @api_shadow
    end

    defp drift(what) do
      """
      BEHAVIOURAL DRIFT between the two TOTP test helpers.

        what drifted : #{what}
        api twin     : #{@api_helper}
        cloud twin   : #{@cloud_helper}

      These two modules are hand-typed twins — cloud/ is a separate mix project
      and cannot load api/test/support, so the contract is duplicated on purpose.
      They still EXPORT the same names (the CONTRACT PARITY test above is green),
      but they no longer BEHAVE the same, which is precisely what a name/arity
      check cannot see.

      WHAT TO DO: open both files, decide which side is correct, and port the
      change to the other. Then re-run

          cd cloud && mix test test/barkpark_cloud/totp_test_helper_test.exs

      Do NOT relax this assertion to make it pass. A silently diverged helper
      puts one tree's 2FA suite back on the wall-clock race both helpers exist to
      remove — and the moduledoc would go on promising it cannot happen.
      """
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
