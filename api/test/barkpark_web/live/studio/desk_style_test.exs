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

  # Scorecard row 7: at 640 px the TanStack Studio shows two strips and a
  # 538 px document. The desk's document pane and the Studio editor inside it
  # give way below 600 px as the editor does in the phone bucket (measured:
  # with the 560 px floor back the editor ran 22 px past the window).
  test "a document beside the strips can be narrower than 600 px and is not cut" do
    assert rule(@css, ".dk .dk-doc") =~ "flex: 1 1 600px"
    assert rule(@css, ".dk .dk-edit") =~ "min-width: 0"
    assert rule(@css, ".dk .dk-edit .editor-panel") =~ "min-width: 0"

    assert @css =~
             ".dk .dk-edit .editor-panel .bp-paper-surface, .dk .dk-edit .editor-panel .editor-body, .dk .dk-edit .editor-panel .editor-body.editor-panel-main:not(.bp-paper-body) { min-inline-size: 0; }"
  end

  test "a reference chip's resting border is --fg-dim (3:1 in both themes), not --border-subtle" do
    body = rule(@css, ".dk .dk-ref")
    assert body =~ "var(--fg-dim)"
    refute body =~ "--border-subtle"
  end

  test "a read-only pane's reference chips do not keep the template's line breaks" do
    # The field's dd is pre-wrap (a multi-line value keeps its lines); in the
    # chips' dd that drew each chip as a 68 px box with its title pushed right.
    assert rule(@css, ".dk .dk-fields dd") =~ "white-space: pre-wrap"
    assert rule(@css, ".dk .dk-fields dd.dk-refs") =~ "white-space: normal"
  end

  test "reference chips are the desk's small text, in the edit strip as in a read-only pane" do
    # The edit strip is not in a dd, so it took the page's 16 px.
    assert rule(@css, ".dk .dk-refs") =~ "font-size: var(--text-sm)"
  end

  test "a note wraps a long unbroken value (a rev of 200 characters) inside its pane" do
    assert rule(@css, ".dk .dk-note") =~ "overflow-wrap: anywhere"
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

  # list.spec J24: the list search's lit result is filled as a row under the pointer
  # is. The Studio's row hover is `.pane-item:hover { background: var(--bg-muted) }`
  # (root.html.heex), so the lit row takes that same token; without the rule its
  # `a` is transparent. A selected row keeps its own fill.
  test "the lit search row's link has the row-hover fill (--bg-muted), not transparent" do
    lit = rule(@css, ".dk [data-lit] > a.pane-item:not(.selected)")
    assert lit =~ "background: var(--bg-muted)"

    root = File.read!(Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__))
    assert root =~ ".pane-item:hover { background: var(--bg-muted);"
  end

  test "the search hits popover fits a phone screen" do
    assert rule(@css, ".dk-search-hits") =~ "width: min(420px, calc(100% - 32px))"
  end

  # Feel walk 2: the popover drew as the browser's default buttons in a black
  # box, as no rule named its classes. TanStack's: a card, an uppercase
  # label, padded rows and a check on the current sort.
  test "the List options popover is a card like the document menu, with its label and a check" do
    assert @css =~
             ".dk .dk-list-menu { min-width: 220px; padding: 4px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); border-radius: 8px; }"

    assert @css =~ ~r/\.dk \.dk-list-menu \.menu-label \{[^}]*text-transform: uppercase/

    assert @css =~
             ~r/\.dk \.dk-list-menu \[role="menuitemradio"\] \{[^}]*border: 0; background: none;/

    assert @css =~
             ~s(.dk .dk-list-menu [role="menuitemradio"][aria-checked="true"]::after { content: "✓";)
  end

  # focus:165: Inspect fits the window and scrolls inside, in one place; Raw
  # JSON in a mono that starts with ui-monospace, a long value on one line.
  test "Inspect has one scroller, its body; Raw JSON is mono, unwrapped" do
    assert rule(@css, ".dk .dk-inspect-body") =~ "overflow: auto"
    assert rule(@css, ".dk .dk-inspect-body") =~ "min-height: 0"
    refute rule(@css, ".dk .dk-inspect-panel") =~ "overflow"
    pre = rule(@css, ".dk .dk-inspect-panel pre")
    assert pre =~ "font-family: var(--paper-font-mono, ui-monospace,"
    assert pre =~ ~r/white-space: pre;/
    assert rule(@css, ".dk .dk-inspect-panel pre code") =~ "font: inherit"
  end

  # Feel walk 2: the Studio's sheet hides a row's chevron until hover or
  # select; TanStack shows it on every row at half opacity. Hover and the
  # selected row (the Studio's rules, more specific) still show it whole.
  test "a row's chevron shows at rest, at half opacity, as TanStack's" do
    assert @css =~ ".dk .pane-item-chevron { opacity: 0.5; }"
  end

  # LOOKS (main, 2026-11-13): the desk takes the TanStack Studio's own
  # colours, light and dark, as `--dk-*` properties. A literal colour is
  # allowed only there; a rule reads it through `var(--dk-…)`.
  test "the sheet's literal colours are only --dk-* properties" do
    refute @css =~ ~r/#[0-9a-fA-F]{3,8}\b/
    rest = Regex.replace(~r/--dk-[a-z-]+: rgb\(\d+ \d+ \d+\);?/, @css, "")
    refute rest =~ ~r/\b(rgb|rgba|hsl|hsla)\(/
  end
end
