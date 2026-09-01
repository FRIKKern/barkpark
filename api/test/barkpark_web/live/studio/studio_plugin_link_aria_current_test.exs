defmodule BarkparkWeb.Studio.StudioPluginLinkAriaCurrentTest do
  @moduledoc """
  spd-bl-plugin-link-aria-current — the `:plugin_link` desk anchor announces
  its selection state.

  The desk used to speak selection in three vocabularies (aria-current="true"
  on rows, "page" on crumbs, aria-selected on chips) and be SILENT in a fourth
  place: the `a.pane-item.nav-plugin-entry` anchors. The fix gives the anchor
  `aria-current="page"` — the page token, because an anchor's destination is a
  page — when the URL names it as the destination (`item.id ==
  pane[:selected]`, the same predicate every sibling row uses).

  The anchors REMAIN anchors: they navigate by plain href, and converting them
  to buttons is explicitly refused in the task (wrong semantics + it would
  break the documented `.pane-item` rhythm decision). Criterion 2's proof is
  the PR diff, but the shape is pinned here too: the element is an `<a href>`,
  not a button.

  Fixture: the Media plugin's "Media Library" `:plugin_link` — the same
  deterministic media-schema seed `scoped_studio_mount_test.exs` uses.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Repo

  @dataset "production"

  setup do
    # Both media schemas → the "Media Library" :plugin_link nests inside the
    # "media-desk" group (Structure.build_media_group/2). list_schemas dedups
    # by name, so these inserts just pin the shape deterministically.
    for spec <- [
          %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
          %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
        ] do
      %Barkpark.Content.SchemaDefinition{}
      |> Barkpark.Content.SchemaDefinition.changeset(
        Map.merge(spec, %{visibility: "private", dataset: @dataset, fields: []})
      )
      |> Repo.insert!()
    end

    :ok
  end

  defp anchor(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#plugin-link-media-library")
    |> Enum.to_list()
  end

  test "the anchor stays an anchor and carries NO aria-current when it is not the destination",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/media-desk"))

    anchors = anchor(html)

    assert match?([_], anchors),
           "the media-desk pane should render the Media Library link, got #{inspect(anchors)}"

    [link] = anchors

    # An <a href>, not a button (criterion 2's shape, pinned in-DOM).
    assert [href] = LazyHTML.attribute(link, "href")
    assert href =~ "/studio/media"
    refute html =~ ~s(<button id="plugin-link-media-library")

    # Not the destination here — silence is correct, and it is what makes the
    # "page" assertion below able to fail (a hardcoded aria-current would red
    # this arm).
    assert LazyHTML.attribute(link, "aria-current") == []
  end

  test ~s(the anchor carries aria-current="page" when the URL names it as the destination),
       %{conn: conn} do
    # A `:plugin_link` is a terminal node: `PaneBuilder.walk_path` keeps the
    # parent list pane (with `selected` = this link's id) and opens no editor,
    # so the desk renders with the link as the current destination.
    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/media-desk/media-library"))

    assert [link] = anchor(html)
    assert LazyHTML.attribute(link, "aria-current") == ["page"]
  end
end
