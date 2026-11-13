defmodule BarkparkWeb.Studio.Desk.SearchLookTest do
  @moduledoc """
  LOOKS C2 (audit screen 8): the desk's search dialog (`DeskLive`'s
  `dialog#dk-search-dialog`) is drawn as the TanStack Studio's search dialog
  (barkpark-studio `Search.tsx`, styles.css `.search-dialog`): 800 px wide at
  12 % of the window, rounded, with TanStack's shadow, its box on top with a
  close, each hit a 49 px row with the type's tile, the title in the desk's
  ink, the type as a badge and the status dot. The combobox the keys drive
  is the one it was (`desk_search_options_test.exs`); the dialog's open and
  close are `bp-desk.js`'s. Pure: renders the component to a string.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.{Search, Style}

  @css Style.sheet(%{}) |> rendered_to_string()

  defp rule(selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector} in the desk stylesheet")
    end
  end

  defp box(query, hits) do
    render_component(&Search.box/1,
      query: query,
      hits: hits,
      root: %Node{items: []},
      base: "/w/a/p/b/d/production/studio/_desk"
    )
  end

  @hits [
    %{
      id: "a",
      type: "post",
      type_title: "Post",
      type_icon: "document",
      title: "Alpha",
      status: "published"
    },
    %{
      id: "b",
      type: "post",
      type_title: "Post",
      type_icon: "document",
      title: "Beta",
      status: "draft"
    }
  ]

  test "the box is TanStack's bar: the search glyph, the box, the dialog's close" do
    html = box("al", @hits)

    assert html =~
             ~r/<div class="dk-search-bar" role="search">\s*<svg[^>]*data-desk-glyph="search"/

    assert html =~ ~s(id="desk-search-input")
    assert html =~ ~r/<form method="dialog">\s*<button[^>]*class="dk-search-close"/
  end

  test "each hit carries the type's tile, the title, the type badge and its status" do
    [first, second] =
      Regex.scan(~r/<a[^>]*data-desk-hit.*?<\/a>/s, box("al", @hits)) |> Enum.map(&hd/1)

    assert first =~ ~r/class="[^"]*dk-search-hit/
    assert first =~ ~r/<span class="dk-media"[^>]*>\s*<svg/
    assert first =~ ~r/<span class="dk-row-title">Alpha<\/span>/
    assert first =~ ~r/<span class="dk-badge">Post<\/span>/
    assert first =~ ~s(class="dk-dot")
    assert second =~ ~s(class="dk-ring dk-draft")
  end

  test "the dialog is 800 wide at 12vh, rounded, with TanStack's shadow and ink" do
    d = rule(".dk-search-dialog")
    assert d =~ "margin: 12vh auto auto"
    assert d =~ "width: min(800px, calc(100vw - 32px))"
    assert d =~ "border-radius: 6px"
    assert d =~ "box-shadow: var(--dk-toast-shadow)"
    assert d =~ "color: var(--dk-fg)"
  end

  test "a hit is a row in the desk's ink, not grey, its badge beside the title" do
    hit = rule(".dk a.dk-search-hit")
    assert hit =~ "min-height: 49px"
    assert hit =~ "padding: 5px 8px"
    assert hit =~ "color: var(--dk-fg)"
    assert rule(".dk .dk-badge") =~ "color: var(--dk-badge-fg)"

    assert rule(".dk a.dk-search-hit .dk-status") =~ "width: 17px",
           "the dot and the ring share one column, so the badges line up"
  end
end
