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

  # LOOKS, group A (main 11-13): rows as the TanStack Studio's (styles.css
  # `.type-row`, `.preview`): inset 12 px, rounded 3 px, 33 px for a structure
  # row and 49 px for a document row, 13/19 px words.
  test "rows are TanStack's: inset, rounded, its heights and type" do
    assert rule(@css, ".dk .dk-rows") =~ "padding: 0 12px 12px"
    row = rule(@css, ".dk .dk-row > .pane-item")

    for want <- [
          "border-radius: 3px",
          "padding: 7px 8px",
          "min-height: 33px",
          "font-size: 13px",
          "line-height: 19px",
          "font-weight: 500",
          "border: 0"
        ] do
      assert row =~ want
    end

    doc = rule(@css, ~s(.dk [data-pane-kind="list"] .dk-row > a.pane-item[data-desk-opens="doc"]))
    assert doc =~ "min-height: 49px"
    assert doc =~ "padding: 5px 8px"
  end

  # TanStack: a row whose pane is the last one open is solid blue with white
  # words (`aria-current`); once a pane is open further right, the soft chain
  # fill (`data-selected`). No green bar.
  test "a selected row is TanStack's blue, and its soft fill once a pane is open past it" do
    assert rule(@css, ".dk .dk-row > a.pane-item.selected") =~
             "background: var(--dk-selected); color: var(--dk-on-selected);"

    assert rule(@css, ".dk .dk-row > a.pane-item.selected .dk-row-sub") =~
             "color: var(--dk-on-selected-soft)"

    chain =
      ".dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving]))"

    assert rule(@css, chain <> " .dk-row > a.pane-item.selected") =~
             "background: var(--dk-row-chain-bg)"

    assert rule(@css, chain <> ~s( .dk-row > a.pane-item.selected[data-desk-opens="doc"])) =~
             "background: var(--dk-hover-strong)"

    assert rule(@css, ".dk .dk-row > .pane-item") =~ "border: 0"
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
  # is: TanStack's `[data-lit] > a.preview` takes its row hover, --card-hover.
  # A selected row keeps its own fill.
  test "the lit search row's link has the row-hover fill, not transparent" do
    lit = rule(@css, ".dk [data-lit] > a.pane-item:not(.selected)")
    assert lit =~ "background: var(--dk-card-hover)"
    assert rule(@css, ".dk .dk-row > a.pane-item:hover:not(.selected)") =~ "var(--dk-card-hover)"
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
    assert @css =~
             ".dk .pane-item-chevron, .dk .pane-item:hover .pane-item-chevron, .dk .pane-item.selected .pane-item-chevron { opacity: 0.5; color: inherit;"
  end

  # LOOKS A3: TanStack's pane header (styles.css `.pane-header`, `.icon-btn`):
  # 49 px for a list or type pane, no bottom line, a 13/19 w600 title in
  # --fg-header, 25 px icon buttons; the list's "×" is out of sight on a wide
  # desk (TanStack has none) until Tab reaches it, and stays as the narrow
  # desk's back arrow.
  test "a list pane's header is TanStack's: 49 px, no line, w600 title, 25 px buttons" do
    head = rule(@css, ".dk .dk-pane:not(.dk-doc) > .pane-header")
    assert head =~ "height: 49px"
    assert head =~ "padding: 0 12px 0 20px"
    assert head =~ "border-bottom: 0"

    title = rule(@css, ".dk .dk-pane:not(.dk-doc) > .pane-header .pane-header-title")

    assert title =~
             "font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-fg-header)"

    btn = rule(@css, ".dk .dk-pane:not(.dk-doc) > .pane-header .icon-btn")
    assert btn =~ "width: 25px; height: 25px"
    assert btn =~ "color: var(--dk-icon-muted)"

    # Out of sight but in the tab order: Tab reaches it and shows it, Enter closes.
    close =
      rule(
        @css,
        ".dk:not([data-narrow]) .dk-pane:not(.dk-doc) > .pane-header .dk-close:not(:focus-visible)"
      )

    assert close =~ "clip-path: inset(50%)"
    refute close =~ "display: none"
  end

  test "the list search is borderless, with the magnifier inside at the left" do
    assert rule(@css, ".dk .dk-list-search") =~ "margin: -1px 12px 7px"

    assert rule(@css, ".dk .dk-list-search .search-icon") =~
             "position: absolute; left: 2px; top: 2px"

    input = rule(@css, ".dk .dk-list-search input")
    assert input =~ "border: 0"
    assert input =~ "background: none"
    assert input =~ "padding: 3px 8px 3px 29px"
    assert rule(@css, ".dk .dk-list-search input::placeholder") =~ "var(--dk-placeholder)"
  end

  test "a plain divider is TanStack's hr: inset 12 px, one --dk-border line" do
    assert rule(@css, ".dk .pane-divider") =~
             "margin: 4px 12px; padding: 0; border: 0; border-top: 1px solid var(--dk-border)"
  end

  # The desk's own look is TanStack's measured values, declared once as
  # `--dk-*` on `.dk` (light) and `html[data-theme="dark"] .dk`, inside the
  # literal gate's skip region; every other rule uses var(--…) only.
  test "literal colours live only in the --dk-* block, light and dark" do
    [_, rest] = String.split(@css, "studio-literal-check: skip-begin", parts: 2)
    [block, after_block] = String.split(rest, "studio-literal-check: skip-end", parts: 2)
    [before_block, _] = String.split(@css, "studio-literal-check: skip-begin", parts: 2)

    for outside <- [before_block, after_block] do
      refute outside =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute outside =~ ~r/\b(rgb|rgba|hsl|hsla)\(/
    end

    assert block =~ ".dk { --dk-fg: #252837;"
    assert block =~ "--dk-selected: #465be8; --dk-on-selected: #fff;"
    assert block =~ ~s(html[data-theme="dark"] .dk { --dk-fg: #e4e5e9;)
    assert block =~ "--dk-selected: #7898ff; --dk-on-selected: #0d0e12;"
  end
end
