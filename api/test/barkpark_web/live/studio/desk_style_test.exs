defmodule BarkparkWeb.Studio.Desk.StyleTest do
  @moduledoc """
  Pins the desk stylesheet's contrast and touch rules (task J45/J46). The
  ratios were measured in a browser on guerrilla, light and dark; this test
  only keeps the token choices and the coarse-pointer block from drifting
  back. Pure: renders the component to a string, no database.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BarkparkWeb.Studio.Desk.Style

  @css Style.sheet(%{}) |> rendered_to_string()

  # The declaration block of the first rule whose selector list is exactly `selector`.
  defp rule(css, selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector} in the desk stylesheet")
    end
  end

  defp coarse_block(css) do
    [_, after_media] = String.split(css, "@media (pointer: coarse) {", parts: 2)
    after_media
  end

  test "a reference chip's resting border is --fg-dim (3:1 in both themes), not --border-subtle" do
    body = rule(@css, ".dk .dk-ref")
    assert body =~ "var(--fg-dim)"
    refute body =~ "--border-subtle"
  end

  test "skeleton bones and pane separators are --border, visible in dark" do
    assert rule(@css, ".dk .dk-bone") =~ "background: var(--border)"
    assert rule(@css, ".dk .dk-pane") =~ "border-right-color: var(--border)"
  end

  test "a selected row's sub line is --fg (--fg-muted is 4.2:1 on the selected fill)" do
    assert rule(@css, ".dk a.pane-item.selected .dk-row-sub") =~ "color: var(--fg)"
  end

  test "reference chips and the close link have the rows' focus ring" do
    ring = "outline: 2px solid var(--primary); outline-offset: -2px;"
    assert rule(@css, ".dk a.pane-item:focus-visible") =~ ring
    assert rule(@css, ".dk .dk-ref:focus-visible") =~ ring
    assert rule(@css, ".dk .dk-close:focus-visible") =~ ring
  end

  test "on a touch screen rows, the close link and reference chips are at least 44 px" do
    coarse = coarse_block(@css)
    assert rule(coarse, ".dk .pane-item") =~ "min-height: 44px"

    for sel <- [".dk .dk-close", ".dk .dk-ref"] do
      body = rule(coarse, sel)
      assert body =~ "min-height: 44px", sel
      assert body =~ "min-width: 44px", sel
    end

    # The mouse layout keeps its sizes: no 44 px outside the coarse block.
    [mouse, _] = String.split(@css, "@media (pointer: coarse) {", parts: 2)
    refute mouse =~ "44px"
  end

  test "the search hits popover fits a phone screen" do
    assert rule(@css, ".dk-search-hits") =~ "width: min(420px, calc(100% - 32px))"
  end

  test "the sheet uses design tokens only, no literal colours" do
    refute @css =~ ~r/#[0-9a-fA-F]{3,8}\b/
    refute @css =~ ~r/\b(rgb|rgba|hsl|hsla)\(/
  end
end
