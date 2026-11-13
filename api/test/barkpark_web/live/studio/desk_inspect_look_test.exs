defmodule BarkparkWeb.Studio.Desk.InspectLookTest do
  @moduledoc """
  LOOKS C3 (audit screen 10): the desk's Inspect dialog is the TanStack
  Studio's card (barkpark-studio `app/src/styles.css` `.dialog.inspect`,
  `.inspect-tabs`, `.inspect-body`, `.json-tree`, `--syntax-*`): radius 6,
  no border, the popover shadow, the title in italics, pill tabs, the body
  in a monospace with the syntax colours light and dark, and no green focus
  ring. Pure: renders the stylesheet to a string.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BarkparkWeb.Studio.Desk.Style

  @css Style.sheet(%{}) |> rendered_to_string()

  defp rule(selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector} in the desk stylesheet")
    end
  end

  test "the card: radius 6, no border, the popover shadow" do
    card = rule(".dk .dk-inspect")

    for want <- ["border: 0", "border-radius: 6px", "box-shadow: var(--dk-popover-shadow)"],
        do: assert(card =~ want)

    assert rule(".dk .dk-inspect-head h2 em") =~ "font-style: italic"
  end

  # Final re-shoot, tell 3: TanStack's `.inspect-backdrop` dims the doc
  # pane's form only, the card 12 px in and stretched across, centred while
  # short (`place-items: center stretch`), and the whole window below 600 px.
  test "Inspect is TanStack's layer over the edit pane's form, not the page's backdrop" do
    refute @css =~ ".dk-inspect::backdrop"

    layer = rule(".dk .dk-inspect-layer")

    for want <- [
          "position: absolute",
          "position-anchor: --dk-edit-body",
          "top: anchor(top)",
          "right: anchor(right)",
          "bottom: anchor(bottom)",
          "left: anchor(left)",
          "place-items: center stretch",
          "padding: 12px",
          "background: var(--dk-backdrop)"
        ],
        do: assert(layer =~ want, "the layer has #{want}")

    # The form is the anchor and stays unpositioned: the Studio's own
    # dialogs in it mean the page (see Style's moduledoc).
    body = rule(".dk .dk-edit-body")
    assert body =~ "anchor-name: --dk-edit-body"
    refute body =~ "position"

    assert rule(".dk .dk-inspect-layer:not(:has(> dialog[open]))") =~ "display: none"

    assert @css =~
             ~r/@media \(max-width: 599px\) \{ \.dk \.dk-inspect-layer \{ position: fixed; inset: 0; \} \}/

    card = rule(".dk .dk-inspect")

    for want <- ["position: static", "margin: 0", "width: auto", "max-height: 100%"],
        do: assert(card =~ want)
  end

  test "the tabs are TanStack's pills: 3 8, radius 3, the selected fill" do
    tab = rule(~s(.dk .dk-inspect-tabs [role="tab"]))
    assert tab =~ "padding: 3px 8px"
    assert tab =~ "border-radius: 3px"
    assert tab =~ "font-weight: 500"

    assert rule(~s(.dk .dk-inspect-tabs [role="tab"][aria-selected="true"])) =~
             "background: var(--dk-selected-fill); color: var(--dk-tab-selected-fg);"
  end

  test "the tree in a monospace, keys, strings and the rest in TanStack's syntax colours" do
    assert rule(".dk .dk-inspect-body") =~
             "font-family: ui-monospace, SFMono-Regular, Menlo, monospace"

    assert rule(".dk .dk-inspect-key") =~ "margin-right: 1ch; color: var(--dk-syntax-property)"
    assert rule(~s(.dk .dk-inspect-value[data-type="string"])) =~ "color: var(--dk-syntax-string)"

    assert rule(".dk .dk-inspect-count, .dk .dk-inspect-value") =~
             "color: var(--dk-syntax-constant)"

    assert rule(".dk .dk-inspect-tree details[open] > summary::before") =~ ~s(content: "▾")

    assert @css =~ ~r/\.dk \{[^}]*--dk-syntax-property: #4043e7; --dk-syntax-string: #965912;/

    assert @css =~
             ~r/html\[data-theme="dark"\] \.dk \{[^}]*--dk-syntax-property: #7898ff; --dk-syntax-string: #f9be1e;/
  end

  test "the close and the tabs take the blue focus ring, not the green" do
    focus =
      rule(
        ~s(.dk .dk-inspect-close:focus-visible, .dk .dk-inspect-tabs [role="tab"]:focus-visible)
      )

    assert focus =~ "var(--dk-focus)"
    refute focus =~ "var(--primary)"
  end

  test "the search box is TanStack's: the UI font at 15/23, a ringed input, the magnifier inside" do
    assert rule(".dk .dk-inspect-search") =~ "font: 15px/23px 'Inter Variable', Inter"
    assert rule(".dk .dk-inspect-search > svg") =~ "left: 6px"
    input = rule(".dk .dk-inspect-search-input")
    assert input =~ "padding: 6px 12px 6px 35px"
    assert input =~ "box-shadow: inset 0 0 0 1px var(--dk-field-ring)"
    assert rule(".dk .dk-inspect-search-input:focus") =~ "var(--dk-focus-ring)"
    assert rule(".dk .dk-inspect-tree li[hidden]") =~ "display: none"
  end
end
