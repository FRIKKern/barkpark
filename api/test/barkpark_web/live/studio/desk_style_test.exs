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

  # Audit: the draft ring is drawn in --dk-caution-dot, the same orange the
  # blue row swallows. On the blue row it is drawn in the row's own ink, as the
  # published dot is; on the soft chain fill it is orange again.
  test "the draft ring shows on a selected row and on the soft chain fill" do
    assert rule(@css, ".dk .dk-row > a.pane-item.selected .dk-ring") =~
             "box-shadow: inset 0 0 0 1.5px var(--dk-on-selected)"

    chain =
      ".dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving]))"

    assert rule(@css, chain <> " .dk-row > a.pane-item.selected .dk-ring") =~
             "box-shadow: inset 0 0 0 1.5px var(--dk-caution-dot)"
  end

  # Audit: the list search's clear button is TanStack's `.search-clear`: a
  # 25 px icon button inside the box at its right edge, not a bare × on a line
  # of its own.
  test "the list search's clear button sits inside the box as a 25 px icon button" do
    body = rule(@css, ".dk .dk-list-search .search-clear")
    assert body =~ "position: absolute; right: 2px; top: 0;"
    assert body =~ "width: 25px; height: 25px;"
    assert body =~ "border: 0;"
    assert rule(@css, ".dk .dk-list-search .search-clear:focus-visible") =~ "var(--dk-focus-ring)"
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

    # Audit: the mouse rules name the row and the hidden close link with more
    # specific selectors, so a bare `.dk .pane-item` lost (rows stayed 33 px,
    # the list pane's close stayed clipped to 1x1). The coarse block repeats
    # those exact selectors; equal weight, later in the sheet, it wins.
    row = rule(coarse, ".dk .dk-row > .pane-item")
    assert row =~ "height: auto"
    assert row =~ "min-height: 44px"

    hidden =
      ".dk:not([data-narrow]) .dk-pane:not(.dk-doc) > .pane-header .dk-close:not(:focus-visible)"

    shown = rule(coarse, hidden)
    assert shown =~ "position: static"
    assert shown =~ "clip-path: none"
    assert shown =~ "min-width: 44px; min-height: 44px"

    assert rule(coarse, ".dk .dk-list-search .search-clear") =~ "width: 44px; height: 44px"

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

  # LOOKS A4: the search is a dialog as TanStack's, 800 px at 12vh and never
  # wider than the screen less 16 px a side; its hits sit inside it.
  test "the search dialog fits a phone screen, its hits inside it" do
    assert rule(@css, ".dk-search-dialog") =~ "width: min(800px, calc(100vw - 32px))"
    assert rule(@css, ".dk-search-dialog") =~ "margin: 12vh auto auto"
    assert rule(@css, ".dk-search-hits") =~ "position: static; width: auto"
  end

  # Feel walk 2: the popover drew as the browser's default buttons in a black
  # box, as no rule named its classes. Now the desk's one menu look (LOOKS C1,
  # `desk_menu_look_test.exs`): an uppercase label, padded rows and a check on
  # the current sort.
  test "the List options popover is the desk's menu, with its label and a check" do
    assert rule(@css, ".dk .dk-menu .dk-menu-label") =~ "text-transform: uppercase"
    assert rule(@css, ".dk .dk-menu-item") =~ "border: 0; border-radius: 3px; background: none;"

    assert @css =~
             ~s(.dk .dk-menu-item[aria-checked="true"]::after { content: "✓";)
  end

  # A choice already in use ("Default sort" while it is) is faint and lights
  # nothing on hover, as the TanStack Studio's list menu.
  test "a List options choice already in use is faint and has no hover" do
    assert @css =~
             ~s|.dk .dk-menu-item[aria-disabled="true"] { background: none; cursor: default; color: color-mix(in srgb, var(--dk-menu-fg) 14%, var(--dk-bg)); }|

    lit =
      rule(
        @css,
        ".dk :is(.dk-menu .dk-menu-item:hover, .dk-menu:not(:hover) .dk-menu-item:focus-visible):not(:disabled, [aria-disabled=\"true\"])"
      )

    assert lit =~ "background: var(--dk-selected)"
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

  # LOOKS A4: TanStack's `.pane.list, .pane.types` (styles.css): they share
  # the room from 321 to 351 px each, the line inside; a width the editor
  # dragged lifts the cap, as TanStack's resize does.
  test "a list or type pane flexes from 321 to 351 px; a document pane keeps its own" do
    pane = rule(@css, ".dk .dk-pane")
    assert pane =~ "box-sizing: border-box; flex: 1 1 0"
    assert pane =~ "min-width: 321px; max-width: 351px"
    assert rule(@css, ".dk .dk-doc") =~ "min-width: 320px; max-width: none; flex: 1 1 600px"

    js = File.read!(Path.expand("../../../../priv/static/assets/bp-desk.js", __DIR__))
    assert js =~ ~s(min-width: " + px + "px; max-width: none; flex: 0 0 " + px)
    assert js =~ "width: 100%; min-width: 0; max-width: none; flex: 1 1 auto;"
  end

  # The build line under the desk is the old Studio's; TanStack has none. The
  # desk's own sheet hides it, so every other Studio page keeps it.
  test "the desk hides the Studio's build footer, only where a desk is" do
    assert rule(@css, ".studio-shell:has(.dk) > .studio-footer") =~ "display: none"
  end

  # The dividers sit inside `.dk-rows`, which already insets the rows 12 px,
  # so their own margin is 0 at the sides: the line runs 12 px from each pane
  # edge and a titled divider's words start at x 20, the rows' own words, as
  # TanStack's (measured: they were at 32, the inset counted twice).
  test "a divider lines up with the rows: line 12 px in, its words at the rows' x" do
    assert rule(@css, ".dk .pane-divider") =~
             "margin: 4px 0; padding: 0; border: 0; border-top: 1px solid var(--dk-border)"

    titled = rule(@css, ".dk .desk-divider")
    assert titled =~ "margin: 4px 0 8px; padding: 7px 8px 6px;"
    assert titled =~ "color: var(--dk-muted)"
    assert rule(@css, ".dk .dk-rows") =~ "padding: 0 12px 12px"
    assert rule(@css, ".dk .dk-row > .pane-item") =~ "padding: 7px 8px"
  end

  # TanStack's page and panes are one surface, --bg (#13141b dark), and a
  # row's tile is filled with that same colour so only its ring shows.
  test "the desk, its panes and a row's tile share one background, --dk-bg" do
    assert @css =~ ~r/(^|\s)\.dk \{ background: var\(--dk-bg\); \}/
    assert rule(@css, ".dk .dk-pane") =~ "background: var(--dk-bg)"
    assert rule(@css, ".dk .dk-media") =~ "background: var(--dk-bg)"
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

    [light, dark] = String.split(block, ~s(html[data-theme="dark"] .dk {), parts: 2)
    assert light =~ "--dk-bg: #fff;"
    assert light =~ "--dk-focus-ring: #556bfc;"
    assert dark =~ "--dk-bg: #13141b;"
    # TanStack's dark --focus-ring.
    assert dark =~ "--dk-focus-ring: #596ffc;"
  end
end
