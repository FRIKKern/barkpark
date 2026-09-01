defmodule BarkparkCloud.TwoFactorReplayDoorTest do
  @moduledoc """
  THE 2FA VERIFICATION SURFACE HAS EXACTLY ONE DOOR, AND IT IS THE REPLAY-SAFE
  ONE.

  `TwoFactor.matching_step/3` returns the RFC-6238 time-step a code matched at,
  so `Accounts.verify_two_factor_otp/2` can CONSUME that step in a SQL guard and
  make one OTP spendable exactly once. That BEHAVIOUR is measured by
  `two_factor_test.exs` ("the TOTP REPLAY GUARD"); this file guards the SHAPE
  the behaviour rests on, which no behavioural test can see.

  A boolean twin (`valid_otp?(secret, otp) :: boolean`) answers the same
  question WITHOUT the step, so its caller has nothing to consume and the same
  six digits clear every challenge for the full ~90s tolerance window. Such a
  twin sat on this module with ZERO call sites and ZERO tests, named so it read
  as the canonical verifier while `matching_step/3` documented itself as the
  variant ("Like `valid_otp?/2`, but..."). Three instruments each missed it by
  construction: the compiler raises no unused warning for a PUBLIC function, a
  zero-caller sweep counted that `@doc` sentence as a reference, and every
  behavioural 2FA test exercises the live path, which already takes the safe
  door.

  ARM 1 censuses the module's PUBLIC exports for a boolean OTP predicate. ARM 2
  censuses `cloud/lib` for `NimbleTOTP.valid?` CALLS outside `matching_step/3`,
  so a reintroduced twin that dodges the naming rule (`otp_ok/2`, or a copy in
  another module) still reds.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Accounts.TwoFactor

  @lib_root Path.expand("../../lib", __DIR__)
  @two_factor_rel "barkpark_cloud/accounts/two_factor.ex"
  @two_factor_abs Path.join(@lib_root, @two_factor_rel)

  describe "ARM 1 — no boolean OTP verifier is exported" do
    test "matching_step stays public, and no OTP-naming predicate joins it" do
      exports = TwoFactor.__info__(:functions)

      assert {:matching_step, 3} in exports,
             "the step-returning verifier must stay public — it is the door"

      predicates =
        for {name, arity} <- exports,
            n = Atom.to_string(name),
            String.ends_with?(n, "?"),
            String.contains?(n, "otp"),
            do: {name, arity}

      assert predicates == [],
             """
             BarkparkCloud.Accounts.TwoFactor exports a BOOLEAN OTP predicate: \
             #{inspect(predicates)}.

             A boolean cannot carry the time-step, so its caller cannot consume \
             the step, so the same six digits clear every challenge inside the \
             ~90s tolerance window. Use matching_step/3 and consume the step the \
             way Accounts.verify_two_factor_otp/2 does.
             """
    end
  end

  describe "ARM 2 — NimbleTOTP.valid? is called from exactly one function" do
    test "the sole cloud/lib call site is inside TwoFactor.matching_step/3" do
      sites =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> code_lines()
          |> Enum.filter(fn {line, _n} -> String.contains?(line, "NimbleTOTP.valid?(") end)
          |> Enum.map(fn {line, n} ->
            {Path.relative_to(path, @lib_root), n, String.trim(line)}
          end)
        end)

      # ANTI-VACUITY. A wrong @lib_root makes Path.wildcard/1 return [], and an
      # `offenders == []` assertion would then pass having read nothing. The one
      # LEGITIMATE call site must be PRESENT, so this arm asserts exactly 1.
      assert length(sites) == 1,
             """
             NimbleTOTP.valid?/3 must be called from exactly ONE place in \
             cloud/lib — TwoFactor.matching_step/3, whose {:ok, step} return is \
             what makes an OTP single-use. Found #{length(sites)}:

             #{Enum.map_join(sites, "\n", fn {p, n, l} -> "  #{p}:#{n}  #{l}" end)}

             (Zero found means @lib_root is wrong, not that the rule holds.)
             """

      [{path, line, _}] = sites
      assert path == @two_factor_rel

      assert line > matching_step_def_line(),
             "the sole NimbleTOTP.valid? call must sit inside matching_step/3, " <>
               "not in a helper above it"
    end
  end

  # CODE ONLY — comments and @doc/@moduledoc heredocs are stripped before the
  # scan. Not a nicety: this file's own subject is a decoy that hid inside doc
  # PROSE, and the first cut of ARM 2 duly reported two "call sites" because
  # matching_step/3's @doc names `NimbleTOTP.valid?` while explaining the rule.
  # A census that cannot tell a call from a mention would red on its own
  # documentation and teach the next reader to delete the sentence.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, n}, {acc, in_doc?} ->
      trimmed = String.trim(line)
      toggles? = String.contains?(trimmed, ~s("""))

      cond do
        # The closing (or opening) fence itself is never code.
        toggles? -> {acc, not in_doc?}
        in_doc? -> {acc, true}
        String.starts_with?(trimmed, "#") -> {acc, false}
        true -> {[{line, n} | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp matching_step_def_line do
    @two_factor_abs
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(
      &String.starts_with?(String.trim(&1), "def matching_step(secret, otp, now)")
    )
    |> case do
      nil -> flunk("matching_step/3's definition clause moved or was renamed")
      idx -> idx + 1
    end
  end
end
