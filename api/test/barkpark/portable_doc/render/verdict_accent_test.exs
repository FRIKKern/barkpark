defmodule Barkpark.PortableDoc.Render.VerdictAccentTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.DataViz

  # The two SEMANTIC verdict accents (pe-bl-verdict-accent-tokens):
  # design/tokens.json color.verdict derives `loss` (terracotta-red) and `peace`
  # (green) plus their soft grounds across five themes x two modes;
  # paper-surface.css resolves them on `.bp-stat__v--loss/--peace` (the stat
  # VALUE) and `.bp-callout--loss/--peace` (the callout RAIL + wash).
  #
  # A token nobody stamps a class for is a dead token. These are the tests that
  # fail if the CONSUMPTION goes away:
  #
  #   * drop `verdict_mod` from DataViz.stat_html/1  → the stat tests below red.
  #   * delete callout_tone_class("loss")/("peace")  → the callout tests red
  #     (the tone falls back to `info`, so the assertion names the wrong class).
  #
  # The token side is gated separately by `node design/check.mjs` Part F (the
  # slots exist and derive byte-exact) and Part H's verdict arm (the inks clear
  # AA 4.5 on the soft wash AND on the reading page, all themes, both modes).
  #
  # JS mirror: js/packages/react/tests/verdict-accent.parity.test.ts.

  describe "stat verdict" do
    test "loss and peace stamp the value modifier, and only the value" do
      for verdict <- ["loss", "peace"] do
        html =
          DataViz.stat_html(%{
            "type" => "stat",
            "value" => "0",
            "label" => "reviews on the merge",
            "body" => "It shipped unread.",
            "verdict" => verdict
          })

        assert html =~ ~s|<div class="bp-stat__v bp-stat__v--#{verdict}">|,
               "verdict #{inspect(verdict)} did not reach the stat value class"

        # The tile, label and body keep the page voice — the NUMBER carries the
        # judgement. A verdict that leaked onto the tile would make the cell a
        # coloured box and defeat the point.
        assert html =~ ~s|<div class="bp-stat">|
        assert html =~ ~s|<div class="bp-stat__l">|
        refute html =~ ~s|bp-stat--#{verdict}|
      end
    end

    test "an absent or off-vocabulary verdict leaves the bare class (byte-identical to before)" do
      base = %{"type" => "stat", "value" => "42", "label" => "x"}

      for block <- [base, Map.put(base, "verdict", "puce"), Map.put(base, "verdict", "")] do
        html = DataViz.stat_html(block)
        assert html =~ ~s|<div class="bp-stat__v">|
        refute html =~ "bp-stat__v--"
      end
    end

    test "a verdict rides through the stats grid onto its own cell" do
      html =
        DataViz.stats_html(%{
          "type" => "stats",
          "items" => [
            %{"value" => "0", "label" => "reviews", "verdict" => "loss"},
            %{"value" => "12", "label" => "tests", "verdict" => "peace"},
            %{"value" => "3", "label" => "plain"}
          ]
        })

      assert html =~ ~s|<div class="bp-stat__v bp-stat__v--loss">|
      assert html =~ ~s|<div class="bp-stat__v bp-stat__v--peace">|
      assert html =~ ~s|<div class="bp-stat__v">|
    end
  end

  describe "callout verdict tones" do
    defp callout(tone, extra \\ %{}) do
      Render.render_blocks(
        [
          Map.merge(
            %{
              "id" => "v",
              "type" => "callout",
              "tone" => tone,
              "content" => [%{"type" => "text", "value" => "x"}]
            },
            extra
          )
        ],
        %{style: :article}
      )
    end

    test "loss and peace map to their own rail modifier, not the info fallback" do
      for tone <- ["loss", "peace"] do
        html = callout(tone)

        assert html =~ ~s(<div class="bp-callout bp-callout--#{tone}">),
               "verdict tone #{inspect(tone)} did not map to its own modifier class"

        refute html =~ "bp-callout--info"
      end
    end

    test "the collapsible form carries the verdict rail and a sentence-cased default summary" do
      html = callout("loss", %{"collapsible" => true})
      assert html =~ ~s(<details open class="bp-callout bp-callout--loss">)
      assert html =~ ~s(<summary class="bp-callout__summary">Loss</summary>)
    end

    test "the five system tones are untouched by the two new ones" do
      for tone <- ["success", "warning", "danger", "neutral", "info"] do
        assert callout(tone) =~ ~s(<div class="bp-callout bp-callout--#{tone}">)
      end

      assert callout("sparkle") =~ ~s(<div class="bp-callout bp-callout--info">)
    end
  end
end
