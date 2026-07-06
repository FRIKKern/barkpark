defmodule BarkparkWeb.Studio.PaneBuilderPluginEditorDispatchTest do
  @moduledoc """
  Pins that BOTH document-list branches of `walk_path/7` share ONE editor
  dispatch (`build_editor/6`): a plugin-contributed `:plugin_document_list`
  over a special type must open the same editor a host desk row does.

  Regression guard: pre-fix the `:plugin_document_list` branch had its own
  inline generic-form editor and none of the paper/sheet/graph/mediaAsset
  special cases — a plugin list over `sheet` opened the raw field form
  instead of the collaborative grid.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  defp plugin_list(type) do
    %Node{
      id: "plugin-doclist-1",
      title: "Plugin list",
      type: :plugin_document_list,
      type_name: type,
      filter: %{}
    }
  end

  defp wrap(node), do: %Node{id: "root", type: :list, items: [node]}

  defp walk(path, root, dataset),
    do: PaneBuilder.walk_path(path, 0, root, [], nil, dataset, [])

  test "a plugin doc list over sheet opens the grid editor (view: :sheet)" do
    dataset = "pbd_plugin_sheet"

    insert_schema!(%{
      name: "sheet",
      title: "Sheets",
      icon: "grid",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })

    {:ok, _} = Content.create_document("sheet", %{"_id" => "s1", "title" => "Sheet 1"}, dataset)

    {_panes, editor} = walk(["plugin-doclist-1", "s1"], wrap(plugin_list("sheet")), dataset)

    assert editor.view == :sheet, "plugin sheet list must open the grid, not the field form"
    assert editor.type == "sheet"
  end

  test "a plugin doc list over mediaAsset with no doc opens the media explorer" do
    dataset = "pbd_plugin_media"

    insert_schema!(%{
      name: "mediaAsset",
      title: "Media Asset",
      icon: "image",
      visibility: "private",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })

    {_panes, editor} = walk(["plugin-doclist-1"], wrap(plugin_list("mediaAsset")), dataset)

    assert editor[:view] == :media_explorer
    assert editor[:kind_filter] == "all"
  end

  test "a plugin doc list over an ordinary type still opens the field form (back-compat)" do
    dataset = "pbd_plugin_plain"

    insert_schema!(%{
      name: "note",
      title: "Notes",
      icon: "file",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })

    {:ok, _} = Content.create_document("note", %{"_id" => "n1", "title" => "Note 1"}, dataset)

    {_panes, editor} = walk(["plugin-doclist-1", "n1"], wrap(plugin_list("note")), dataset)

    refute Map.has_key?(editor, :view)
    assert editor.type == "note"
    assert is_map(editor.form)
  end
end
