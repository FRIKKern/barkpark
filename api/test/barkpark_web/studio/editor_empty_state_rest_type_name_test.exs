defmodule BarkparkWeb.Studio.EditorEmptyStateRestTypeNameTest do
  @moduledoc """
  The `:no_schema` notice names the TYPE, not the …Rest node id.

  Found on the stranger walk (2026-09-30): `/studio/nosuchtype` on a dataset
  holding a schemaless `nosuchtype` document said "No schema for
  rest-nosuchtype is installed in this dataset (you asked for nosuchtype)".
  `Structure` ids a …Rest row `"rest-<type>"`, the bare URL is normalized into
  that column, and the notice read the pane's `:selected` node id as the type.
  The sibling seam tests fixture the row with an id that is not Structure's
  shape, so they never saw the prefix.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared

  # Structure's own shape for a schemaless orphan under …Rest
  # (`Barkpark.Structure.rest_child_node/3`).
  defp root do
    %Node{
      id: "root",
      title: "Content",
      type: :list,
      items: [
        %Node{
          id: "rest",
          title: "…Rest",
          type: :list,
          items: [
            %Node{
              id: "rest-orphanType",
              title: "orphanType (1)",
              icon: "file",
              type: :document,
              type_name: "orphanType"
            }
          ]
        }
      ]
    }
  end

  defp panes(segments) do
    tree = root()

    root_pane = %{
      title: tree.title,
      role: :nav,
      priority: 0,
      items: PaneBuilder.list_items(tree),
      selected: Enum.at(segments, 0)
    }

    {panes, editor} =
      PaneBuilder.walk_path(segments, 0, tree, [root_pane], nil, "spdw_rest_type_name", [])

    assert editor == nil, "a schemaless orphan must not resolve an editor"
    panes
  end

  test "a bare /studio/<type> URL names the type, and asks for nothing else" do
    # The URL said `orphanType`; resolve/4 normalized it to the …Rest row.
    st = Shared.empty_editor_state(panes(["rest", "rest-orphanType"]), ["orphanType"])

    assert st == %{reason: :no_schema, doc_id: "orphanType", doc_type: "orphanType"}
  end

  test "/studio/<type>/<id> names the type and the id asked for" do
    st =
      Shared.empty_editor_state(panes(["rest", "rest-orphanType"]), ["orphanType", "doc-1"])

    assert st == %{reason: :no_schema, doc_id: "doc-1", doc_type: "orphanType"}
  end

  test "the …Rest pane's rows carry the type they stand for" do
    [_root, rest_pane] = panes(["rest", "rest-orphanType"])
    [row] = rest_pane.items
    assert row.id == "rest-orphanType"
    assert row.type_name == "orphanType"
  end
end
