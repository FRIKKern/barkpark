defmodule BarkparkWeb.Studio.Desk.MenuLookTest do
  @moduledoc """
  LOOKS C1 (audit screens 6 and 7): the desk's three popover menus (a list's
  "List options", the edit pane's "Show document actions" and "Share
  document") are one menu, the TanStack Studio's `.popover.menu`
  (barkpark-studio `app/src/styles.css`): no border, its popover shadow in
  both themes, 33 px items in its menu ink at weight 500, each with a 21 px
  icon, a check on the sort in use, and nothing lit until the pointer or the
  keys put it there. Pure: renders the components to strings, no database.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]

  alias BarkparkWeb.Studio.Desk.{DocMenu, ListMenu, Panes, ShareMenu, Style}

  @css Style.sheet(%{}) |> rendered_to_string()

  defp rule(selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector} in the desk stylesheet")
    end
  end

  defp list_menu(sort) do
    %{
      id: "desk-pane-1",
      index: 1,
      sort: sort,
      default: "updated",
      orderings: [%{title: "Publish date, newest", sort: "publishedAt:desc"}],
      named: [],
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
    |> then(fn a -> render_component(&ListMenu.menu/1, a) end)
  end

  defp doc_menu do
    items =
      for {label, event} <- [
            {"Unpublish", "unpublish"},
            {"History", "show-history"},
            {"Duplicate", "duplicate-doc"},
            {"Delete", "delete-doc"}
          ],
          do: %{label: label, event: event}

    render_component(&DocMenu.menu/1, id: "desk-pane-2-actions", items: items, place: :header)
  end

  defp share_menu do
    chain = Panes.parse("post;post-01")

    %{
      id: "desk-pane-1-share",
      doc: %{doc_id: "post-01"},
      chain: chain,
      index: length(chain) - 1,
      base: "/w/a/p/b/d/c/studio/_desk"
    }
    |> then(fn a -> render_component(&ShareMenu.menu/1, a) end)
  end

  # The words of each item, in order (the icon follows them in the markup).
  defp labels(html),
    do: for([_, l] <- Regex.scan(~r/class="dk-menu-item[^"]*"[^>]*>([^<]+)</, html), do: l)

  test "all three menus are the one desk menu, each item with its 21 px icon" do
    for html <- [list_menu(nil), doc_menu(), share_menu()] do
      assert html =~ ~r/<div[^>]*popover[^>]*role="menu"/
      assert html =~ ~r/<div[^>]*class="[^"]*\bdk-menu\b/
      items = Regex.scan(~r/<button[^>]*class="dk-menu-item[^"]*"/, html)
      assert items != []

      icons =
        Regex.scan(~r/<span class="dk-menu-icon" aria-hidden="true">\s*<svg[^>]*width="21"/, html)

      assert length(icons) >= length(items) - 1, "every item but Default sort has an icon"
    end
  end

  test "the list menu: an Actions label, a sort glyph per sort, a check on the sort in use" do
    html = list_menu("updated")
    assert html =~ ~s(class="menu-label dk-menu-label">Actions</div>)

    assert labels(html) == [
             "Sort by Publish date, newest",
             "Sort by Last Edited",
             "Sort by Created",
             "Default sort"
           ]

    assert html =~ ~r/aria-checked="true"[^>]*>Sort by Last Edited<span class="dk-menu-icon"/
    assert html =~ ~r/data-desk-icon="sort"/
    # Default sort draws no icon, as TanStack's.
    assert html =~ ~r/>Default sort<\/button>/
  end

  test "the document menu: each action with its glyph, Delete in red under a line" do
    html = doc_menu()
    assert labels(html) == ["Unpublish", "History", "Duplicate", "Delete"]

    assert html =~
             ~r/<hr class="dk-menu-sep"\/?>\s*<button[^>]*class="dk-menu-item danger"[^>]*data-desk-doc-action="delete-doc"/

    assert html =~ ~s(data-desk-icon="unpublish")
    assert html =~ ~s(data-desk-icon="restore")
  end

  test "the Share menu lists the URL first, as TanStack's" do
    assert labels(share_menu()) == ["Copy document URL", "Copy document ID"]
  end

  test "the menu box: radius 6, no border, the popover shadow, in both themes" do
    box = rule(".dk .dk-menu")

    for want <- [
          "border: 0",
          "border-radius: 6px",
          "padding: 4px",
          "box-shadow: var(--dk-popover-shadow)",
          "background: var(--dk-bg)"
        ],
        do: assert(box =~ want)

    refute box =~ "border: 1px"
    # The ring is in the shadow, light and dark: a dark menu has an edge.
    assert @css =~
             ~r/\.dk \{ --dk-menu-fg: #383d51;[^}]*--dk-popover-shadow: 0 0 0 0\.5px rgba\(114, 120, 146, 0\.3\)/

    assert @css =~
             ~r/html\[data-theme="dark"\] \.dk \{ --dk-menu-fg: #bdbfcb;[^}]*--dk-popover-shadow: 0 0 0 0\.5px rgba\(117, 123, 150, 0\.4\)/

    # A popover is hidden by the browser's display: none; the flex is only for an open one.
    assert rule(".dk .dk-menu:popover-open") =~ "display: flex; flex-direction: column; gap: 4px;"
  end

  test "an item is TanStack's: 33 px, pad 7 12, 13/19 weight 500 in the menu ink, a 21 px icon first" do
    item = rule(".dk .dk-menu-item")

    for want <- [
          "padding: 7px 12px",
          "font-size: 13px",
          "line-height: 19px",
          "font-weight: 500",
          "color: var(--dk-menu-fg)"
        ],
        do: assert(item =~ want)

    assert rule(".dk .dk-menu-icon") =~ "order: -1"
    assert rule(".dk .dk-menu-icon svg") =~ "width: 21px; height: 21px;"
  end

  # TanStack: "a click opens it unlit". The desk focuses the first item on
  # open (bp-desk.js), so a lit `:focus` lit it on every click; only the
  # pointer or a keyboard focus (`:focus-visible`) lights an item now.
  test "an item is lit under the pointer or a keyboard focus only, never by :focus" do
    refute @css =~ ~r/dk-menu[^{]*:focus[,)\s{][^{]*\{[^}]*background/
    assert rule(".dk .dk-menu-item:focus") =~ "outline: none"

    assert @css =~
             ~S"""
             .dk :is(.dk-menu .dk-menu-item:hover, .dk-menu:not(:hover) .dk-menu-item:focus-visible):not(:disabled, [aria-disabled="true"]) { background: var(--dk-selected); color: var(--dk-menu-hover-fg); }
             """
             |> String.trim()
  end
end
