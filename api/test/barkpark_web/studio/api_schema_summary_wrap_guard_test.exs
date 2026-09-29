defmodule BarkparkWeb.Studio.ApiSchemaSummaryWrapGuardTest do
  @moduledoc """
  studio-r22 — the API tester's schema cards, pinned so a revert REDS OFFLINE.

  THE DEFECT. `/studio/api-tester` renders its Schema reference inside a
  `.pane-column`, and that column is explicitly a SQUEEZING one: it declares
  `flex-shrink: 1` against a fluid `clamp(140px, 18vw, 260px)` floor, so at
  viewport 900 the docs pane lands near 255px. `.api-schema-summary` was a
  no-wrap flex row of four intrinsically-sized chips — schema name, title,
  visibility badge, field count — and four such chips do not fit 255px once
  the name is long. Measured on the deployed build: 9 of 40 cards overflowed
  their card, worst 70px, with the field-count chip cut at or pushed outside
  the card border. It reproduced with an 11px control in place of the shipped
  12px `.text-xs`, so it was never a type-scale consequence — it was a missing
  wrap, in a file that uses `min-width: 0` dozens of times elsewhere.

  WHY A SHEET TEST AND NOT A BROWSER ONE. The rule lives in the `<head>`
  `<style>` block of `root.html.heex`. No job that could gate a merge drives a
  real browser, so a geometry proof in Chrome — which is how the overflow was
  found and how the fix was confirmed — cannot carry the revert obligation.
  This file carries it instead, and does it honestly: every predicate below is
  scoped to the rule block it is about (a bare `flex-wrap: wrap` substring
  would match dozens of unrelated rules in this sheet), and every predicate
  carries a SABOTAGE CONTROL — the same predicate re-run against a copy of the
  sheet with the load-bearing declaration cut out must come back FALSE. A
  check whose failure nobody has observed is not a check.

  Deliberately NOT asserted: the pixel geometry itself. This file cannot
  measure a layout; it pins the declarations that produce it.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  defp sheet, do: File.read!(@root)

  # Extract a single CSS rule's declaration block by exact selector, so a
  # predicate can never be satisfied by an unrelated rule elsewhere in the
  # sheet. Returns nil when the selector is absent.
  defp rule_block(css, selector) do
    case Regex.run(~r/(?<![\w.>*\-])#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) do
      [_, body] -> body
      nil -> nil
    end
  end

  defp wraps?(css), do: (rule_block(css, ".api-schema-summary") || "") =~ ~r/flex-wrap:\s*wrap/

  defp children_can_shrink?(css),
    do: (rule_block(css, ".api-schema-summary > *") || "") =~ ~r/min-width:\s*0/

  defp children_can_break?(css),
    do:
      (rule_block(css, ".api-schema-summary > *") || "") =~
        ~r/overflow-wrap:\s*(anywhere|break-word)/

  # Cut a declaration out of ONE named rule, leaving every other rule in the
  # sheet untouched, so a sabotage control can only ever disarm the thing the
  # predicate above claims to read.
  defp cut_decl(css, selector, decl) do
    {:ok, re} = Regex.compile("(?<![\\w.>*-])#{Regex.escape(selector)}\\s*\\{[^}]*\\}")
    [rule] = Regex.run(re, css)
    cut = String.replace(rule, decl, "")
    true = cut != rule
    String.replace(css, rule, cut)
  end

  defp cut_from_summary_rule(css, decl), do: cut_decl(css, ".api-schema-summary", decl)
  defp cut_from_children_rule(css, decl), do: cut_decl(css, ".api-schema-summary > *", decl)

  describe "the summary wraps instead of overflowing its squeezing column" do
    test "`.api-schema-summary` declares flex-wrap, and cutting it REDS" do
      assert wraps?(sheet()),
             "`.api-schema-summary` lost `flex-wrap` — its four chips are back to a " <>
               "no-wrap row in a column that shrinks to ~255px at viewport 900, so a " <>
               "long schema name pushes the field-count chip outside the card again"

      # SABOTAGE CONTROL: without the declaration the predicate must be false.
      # Cut it out of THIS rule specifically. A `global: false` replace of the
      # bare declaration would hit the first `flex-wrap: wrap` anywhere in the
      # sheet — some unrelated rule hundreds of lines earlier — and the refute
      # below would then pass while proving nothing. (It did, on the first
      # draft of this file: the control caught its own test.)
      sabotaged = cut_from_summary_rule(sheet(), "flex-wrap: wrap; ")

      refute wraps?(sabotaged),
             "the flex-wrap check passes on a sheet with flex-wrap CUT OUT — it is " <>
               "matching something else and guards nothing"
    end

    test "the summary is still a flex row (the wrap did not change the display mode)" do
      body = rule_block(sheet(), ".api-schema-summary")
      assert body, "`.api-schema-summary` rule is gone from the sheet entirely"
      assert body =~ ~r/display:\s*flex/
      assert body =~ ~r/align-items:\s*center/
    end

    test "the horizontal gap is unchanged, so cards that already fit render as before" do
      # `gap: <row> <column>` — the column gap stays 12px. Only the row gap
      # (which did not exist before, because nothing ever wrapped) is new.
      assert rule_block(sheet(), ".api-schema-summary") =~ ~r/gap:\s*\S+\s+12px/,
             "the 12px column gap changed — this fix is supposed to be invisible " <>
               "on the cards that never overflowed"
    end
  end

  describe "a single chip longer than the whole line still cannot overflow" do
    # flex-wrap alone cannot save a line holding one over-long item: a flex
    # item's automatic minimum size is its min-content width, so an unbroken
    # 300px token in a 255px column overflows a wrapping row exactly as it
    # overflowed a non-wrapping one. min-width:0 plus a breaking overflow-wrap
    # is what makes the invariant hold for ANY name length.
    test "`.api-schema-summary > *` can shrink below min-content, and cutting it REDS" do
      assert children_can_shrink?(sheet()),
             "the summary's children lost `min-width: 0` — a schema name longer " <>
               "than the column overflows again regardless of flex-wrap"

      sabotaged = cut_from_children_rule(sheet(), "min-width: 0; ")

      refute children_can_shrink?(sabotaged),
             "the min-width check passes with min-width CUT OUT — it guards nothing"
    end

    test "`.api-schema-summary > *` can break an over-long token, and cutting it REDS" do
      assert children_can_break?(sheet()),
             "the summary's children lost their breaking `overflow-wrap` — " <>
               "min-width:0 lets the box shrink but the text still paints past it"

      sabotaged = cut_from_children_rule(sheet(), "overflow-wrap: anywhere; ")

      refute children_can_break?(sabotaged),
             "the overflow-wrap check passes with the declaration CUT OUT — it guards nothing"
    end
  end

  describe "the type scale is not the remedy and was not touched" do
    test "`.text-xs` still resolves straight to its token" do
      # The overflow reproduced with an 11px control, so shrinking type was
      # never the fix. This pins the rule so a future 'fix' cannot quietly
      # become one.
      assert sheet() =~ ".text-xs { font-size: var(--text-xs); }",
             "`.text-xs` changed — the schema-card overflow is a wrap defect, not a " <>
               "type-scale one, and must not be paid for out of the global type scale"
    end
  end
end
