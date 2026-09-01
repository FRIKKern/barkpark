defmodule BarkparkWeb.Studio.StudioPluginLinkEmptyStateTest do
  @moduledoc """
  task-554a33ca42c0c45a — a nav_path terminating in a `:plugin_link` must not
  make the editor shell accuse the desk of losing a document.

  THE OBSERVATION THIS FILE EXISTS TO RECORD. The row asked whether the
  unresolved-document notice flashes "for one frame" before a `push_navigate`
  flushes. Driven, the answer is neither half of that question:

    1. There is NO `push_navigate`. The desk LiveView has no arm that inspects
       `nav_path` for a `:plugin_link` and navigates away — the link rows are
       plain `<a href>` anchors that the BROWSER follows. Mounting the path
       directly (a bookmark, a back button, the aria-current fixture in
       `studio_plugin_link_aria_current_test.exs`) issues no redirect at all,
       which `no push_navigate …` below pins by driving `assert_redirect/2` to
       its "but got none" failure.
    2. So the frame is not intermediate. It is the dead render AND every
       connected render, permanently, for as long as the human stays on the
       URL.

  And on that permanent frame the notice DID render, with `role="alert"` and
  `aria-live="assertive"` — two different lies depending on where the link
  sits, both reproduced below before the fix:

    * nested under a group → last pane is `role: :list` with no `type_name`,
      so `Shared.empty_editor_state/2` returned `:no_schema`: "No schema for
      media-library is installed in this dataset."
    * sitting at the desk root → last pane is `role: :nav` with a selection,
      so it returned `:unknown_node`: "This desk has no section named …" —
      naming the section the human just clicked.

  The fix suppresses BOTH by the shape the row predicted was distinguishable:
  the walk stopped on a `:plugin_link` child, and the terminal pane's own
  `items` still carry it (`PaneBuilder.list_items/2` is the only producer of
  `type: :plugin_link`), so `:selected` can be matched against them.

  NON-VACUITY. Every LiveView case here also asserts the Media Library anchor
  is present and carries `aria-current="page"`. A fixture that stopped
  reaching the `:plugin_link` shape (a renamed node, a disabled plugin, a
  redirect introduced later) would then red rather than pass by rendering
  nothing to complain about.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Repo
  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"

  setup do
    # Both media schemas → the "Media Library" `:plugin_link` nests inside the
    # "media-desk" group (Structure.build_media_group/2). Same deterministic
    # seed as scoped_studio_mount_test.exs / the aria-current test.
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

  defp query(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.to_list()
  end

  defp notices(html), do: query(html, "[data-test-id='studio-unresolved-document-notice']")

  defp reasons(html) do
    html |> notices() |> Enum.flat_map(&LazyHTML.attribute(&1, "data-reason"))
  end

  # The desk really did walk to the plugin link — asserted alongside every
  # absence claim so "no notice" can never mean "no page".
  defp assert_on_the_plugin_link(html) do
    assert [link] = query(html, "#plugin-link-media-library"),
           "fixture must reach the Media Library :plugin_link row"

    assert LazyHTML.attribute(link, "aria-current") == ["page"],
           "the URL must name the plugin link as the destination"

    html
  end

  describe "a nav_path terminating in a nested :plugin_link" do
    test "renders NO unresolved-document notice — dead render and connected render alike",
         %{conn: conn} do
      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/media-desk/media-library"))

      assert_on_the_plugin_link(html)

      assert notices(html) == [],
             "the dead render named a reason for a link, got #{inspect(reasons(html))}"

      connected = render(view)
      assert_on_the_plugin_link(connected)

      assert notices(connected) == [],
             "the connected render named a reason for a link, got #{inspect(reasons(connected))}"

      # The calm state instead: a link is not a document, so no document is
      # open — which is exactly true and does not shout.
      assert [_] = query(connected, "[data-test-id='studio-editor-nothing-selected']")
    end

    test "no push_navigate — the frame is permanent, not intermediate", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/media-desk/media-library"))

      # THE OBSERVATION. If a later refactor makes the LV navigate away from a
      # `:plugin_link` nav_path, this assertion reds and the moduledoc above
      # stops being true — which is the point of pinning an absence.
      assert_raise ArgumentError, ~r/to redirect, but got none/, fn ->
        assert_redirect(view, 100)
      end

      assert Process.alive?(view.pid),
             "the view stayed mounted on the plugin-link path — the frame is the page"
    end
  end

  describe "the derivation, driven through the public walk" do
    # Mirrors PaneBuilder.build/3's entry EXACTLY, including the root pane's
    # `items: list_items(...)`. Seeding `items: []` there would hide the
    # root-level `:plugin_link` shape entirely (the guard keys on the terminal
    # pane's items) and make the root case a false green.
    defp walk(path, root) do
      root_pane = %{
        title: root.title,
        role: :nav,
        priority: 0,
        items: PaneBuilder.list_items(root, ""),
        selected: Enum.at(path, 0)
      }

      {panes, editor} = PaneBuilder.walk_path(path, 0, root, [root_pane], nil, @dataset, [])

      assert editor == nil, "a :plugin_link is terminal — it must produce no editor"

      {panes, Shared.empty_editor_state(panes, path)}
    end

    test "a link at the desk ROOT is not an unknown node" do
      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [
          %Node{
            id: "pulse",
            title: "Pulse",
            type: :plugin_link,
            filter: "/admin/pulse"
          }
        ]
      }

      {panes, state} = walk(["pulse"], root)

      # The shape that USED to produce `:unknown_node`: one pane, role :nav,
      # carrying the selection.
      assert [%{role: :nav, selected: "pulse"}] = panes

      assert state == %{reason: :nothing_selected, doc_id: nil, doc_type: nil}
    end

    test "a link NESTED in a group is not a schemaless type" do
      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [
          %Node{
            id: "media-desk",
            title: "Media",
            type: :list,
            items: [
              %Node{
                id: "media-library",
                title: "Media Library",
                type: :plugin_link,
                filter: "/studio/#{@dataset}/media"
              }
            ]
          }
        ]
      }

      {panes, state} = walk(["media-desk", "media-library"], root)

      # The shape that USED to produce `:no_schema`: a :list pane with a
      # selection and NO type_name.
      assert [_root, %{role: :list, selected: "media-library"} = last] = panes
      refute Map.get(last, :type_name)

      assert state == %{reason: :nothing_selected, doc_id: nil, doc_type: nil}
    end

    test "the suppression is keyed on the plugin link, not on 'a :list pane with a selection'" do
      # The guard must not swallow the real `:no_schema` arm: same pane role,
      # same non-nil selection, but the selected id names a plain item rather
      # than a `:plugin_link`.
      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [
          %Node{
            id: "media-desk",
            title: "Media",
            type: :list,
            items: [
              %Node{
                id: "media-library",
                title: "Media Library",
                type: :plugin_link,
                filter: "/studio/#{@dataset}/media"
              },
              %Node{id: "orphanType", title: "Orphan", type: :document, type_name: "orphanType"}
            ]
          }
        ]
      }

      {_panes, state} = walk(["media-desk", "orphanType"], root)

      assert state == %{
               reason: :no_schema,
               doc_id: "orphanType",
               doc_type: "orphanType"
             }
    end
  end
end
