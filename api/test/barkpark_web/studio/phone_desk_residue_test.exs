defmodule BarkparkWeb.Studio.PhoneDeskResidueTest do
  @moduledoc """
  task-134dd8b12b5ce305 — two phone-bucket defects measured live at 375 and
  420 (emulated, mobile, touch) and fixed with two phone-only rules in
  `root.html.heex`.

  F2. The painted-closed inspector's expand toggle rendered at 16x16 CSS px,
  under the 24x24 minimum target size (WCAG 2.2 SC 2.5.8). The 44px Tier-3
  exit rule deliberately excludes this state (`[data-user-opened]`), so the
  closed strip's button had no floor at all.

  F1. With no document open, the nothing-selected placeholder
  (`.editor-empty { flex: 1 }`) shared the row with the lone list column
  (`.pane-column--last { flex: 1 1 auto }`): list 313.2px + placeholder 61.8px
  at 375, 340px + 80px at 420.

  Pins are literal strings, never values re-derived from the sheet (charter
  D94), and the helpers are duplicated from `inspector_summoned_destination_test.exs`
  on purpose so neither lock can be weakened by an edit aimed at the other.
  This is a source-level contract; the browser measurement is in the PR.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  @closed_toggle ~S|html[data-width-bucket="phone"] .bp-doc-sidebar:not([data-user-opened]) .bp-doc-sidebar__collapse|
  @placeholder ~S|html[data-width-bucket="phone"] .pane-layout:has(> .pane-column--last) > .editor-empty[data-reason="nothing_selected"]|

  # The icon box the toggle renders at without any floor (the base
  # `.bp-doc-sidebar__collapse` rule has no padding and no minimum).
  @icon_px 16

  describe "F2 — the closed inspector toggle is a 24px target at phone" do
    test "the phone rule gives the closed toggle a 24x24 minimum" do
      block = block!([@closed_toggle])

      assert value!(block, "min-width") == "24px"
      assert value!(block, "min-height") == "24px"
      assert value!(block, "justify-content") == "center"
    end

    test "the negative margin gives the growth back: the flex footprint stays the 16px icon" do
      # Without the margin the 41px strip becomes 49px and the reader loses 8px
      # at 375. Measured with the rule: toggle 24x24 at x=343, strip 41px,
      # reader 334px — identical to the 16x16 control on every other box.
      block = block!([@closed_toggle])
      "-" <> margin = value!(block, "margin")
      assert {m, "px"} = Integer.parse(margin)
      assert {min, "px"} = Integer.parse(value!(block, "min-width"))

      assert min - 2 * m == @icon_px,
             "the closed toggle's layout footprint is #{min - 2 * m}px, not the #{@icon_px}px icon — the strip and the reader move"
    end

    test "scoped to phone and to the NOT-user-opened state" do
      # Disjoint from the 44px Tier-3 exit by construction: that rule requires
      # `[data-user-opened]`, this one refuses it.
      assert String.contains?(@closed_toggle, ":not([data-user-opened])")

      for bucket <- ~w(wide standard narrow) do
        refute String.contains?(@closed_toggle, ~s|data-width-bucket="#{bucket}"|)
      end

      # The base rule stays floor-less, so every non-phone bucket keeps its
      # 16px box (live control at 800/narrow: 16x16, margin 0px).
      base = block!([".bp-doc-sidebar__collapse"])
      refute base =~ ~r/(?:^|;)\s*(min-width|min-height|margin)\s*:/
    end
  end

  describe "F1 — with no document open, the phone list owns the width" do
    test "the nothing-selected placeholder yields at phone" do
      assert value!(block!([@placeholder]), "display") == "none"
    end

    test "scoped to phone, to nothing_selected, and to a desk that has a list column" do
      assert String.contains?(@placeholder, ~S|[data-reason="nothing_selected"]|),
             "the hide must not reach the not-found / no-schema notices, which are errors"

      assert String.contains?(@placeholder, ":has(> .pane-column--last)"),
             "without the guard a desk with no list column would render blank"

      for bucket <- ~w(wide standard narrow) do
        refute String.contains?(@placeholder, ~s|data-width-bucket="#{bucket}"|)
      end

      # The base rule is unchanged, so every other bucket still shows it.
      base = block!([".editor-empty"])
      assert value!(base, "flex") == "1"
      refute base =~ ~r/(?:^|;)\s*display\s*:\s*none/
    end

    test "the placeholder markup still carries the hook the rule keys on" do
      src =
        File.read!(
          Path.expand(
            "../../../lib/barkpark_web/components/studio_components/editor.ex",
            __DIR__
          )
        )

      assert src =~
               ~S|<div class="editor-empty" data-test-id="studio-editor-nothing-selected" data-reason="nothing_selected">|,
             "the nothing-selected placeholder lost `data-reason` — the phone rule now matches nothing"
    end
  end

  defp css, do: File.read!(@root)

  defp decommented(src), do: Regex.replace(~r|/\*.*?\*/|s, src, "")

  defp block!(selectors) do
    esc = selectors |> Enum.map(&Regex.escape/1) |> Enum.join(~S|,\s*|)

    case Regex.scan(~r/(?:^|\})\s*#{esc}\s*\{([^{}]*)\}/, decommented(css()),
           capture: :all_but_first
         ) do
      [[one]] ->
        one

      [] ->
        flunk("""
        SELECTOR LIST MATCHED ZERO RULES:

        #{Enum.join(selectors, ",\n")}

        root.html.heex declares no rule with that selector list, so the phone
        geometry it carried is gone (or the rule was renamed — repoint it and
        say so).
        """)

      many ->
        flunk(
          "that selector list now has #{length(many)} rules — the winner is source-order dependent"
        )
    end
  end

  defp value!(block, prop) do
    case Regex.scan(~r/(?:^|;)\s*#{Regex.escape(prop)}\s*:\s*([^;}]+)/, block,
           capture: :all_but_first
         ) do
      [[one]] -> one |> String.trim() |> String.replace(~r/\s+/, " ")
      [] -> flunk("the rule no longer declares `#{prop}`")
      many -> flunk("`#{prop}` is declared #{length(many)} times")
    end
  end
end
