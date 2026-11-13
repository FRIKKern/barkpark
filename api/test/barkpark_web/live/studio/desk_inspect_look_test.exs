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

  test "the card: radius 6, no border, the popover shadow, TanStack's backdrop" do
    card = rule(".dk .dk-inspect")

    for want <- ["border: 0", "border-radius: 6px", "box-shadow: var(--dk-popover-shadow)"],
        do: assert(card =~ want)

    assert rule(".dk .dk-inspect::backdrop") =~ "background: var(--dk-backdrop)"
    assert rule(".dk .dk-inspect-head h2 em") =~ "font-style: italic"
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
end
