defmodule Barkpark.StructureMediaTest do
  @moduledoc """
  Media's place in the tiered desk (studio-structure-polish charter,
  Decisions 3/7): the media plugin declares `structure_placement :top_menu`,
  so by DEFAULT the Media group is OUT of the desk tree (reached via the host
  top-menu Media tab) and its doc types are claimed — they must not leak into
  …Rest. A per-workspace override promoting media to `"main"` restores the
  group with its children.
  """

  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure
  alias Barkpark.Tenancy

  defp insert_media_schemas!(dataset, specs) do
    for spec <- specs do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(
        Map.merge(spec, %{visibility: "private", dataset: dataset, fields: []})
      )
      |> Repo.insert!()
    end
  end

  defp all_type_names(%Structure.Node{items: items}), do: collect_types(items, MapSet.new())

  defp collect_types(items, acc) do
    Enum.reduce(items, acc, fn node, acc ->
      acc = if node.type_name, do: MapSet.put(acc, node.type_name), else: acc
      collect_types(node.items || [], acc)
    end)
  end

  test "build/1 leaves the Media group out of the tree by default (top-menu placement)" do
    dataset = "structure_media_test"

    insert_media_schemas!(dataset, [
      %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
      %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
    ])

    tree = Structure.build(dataset)

    refute Enum.find(tree.items, &(&1.id == "media-desk")),
           "media placement is :top_menu by default → no Media group in the tree"

    # Claimed by the top-menu placement — media types must not leak into …Rest.
    types = all_type_names(tree)
    refute "mediaAsset" in types
    refute "mediaCollection" in types
  end

  test "a workspace override promoting media to main restores the Media group" do
    dataset = "structure_media_promoted"

    insert_media_schemas!(dataset, [
      %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
      %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
    ])

    ws = create_workspace!()

    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(ws.id, %{"media" => %{"placement" => "main"}})

    tree = Structure.build(dataset, workspace_id: ws.id)
    media_node = Enum.find(tree.items, &(&1.id == "media-desk"))

    assert media_node
    assert media_node.title == "Media"

    child_titles = Enum.map(media_node.items, & &1.title)
    assert "Media Library" in child_titles

    child_names = Enum.map(media_node.items, & &1.type_name)
    assert "mediaAsset" in child_names
    assert "mediaCollection" in child_names
  end

  test "promoted media includes the Media Library link when only mediaAsset schema exists" do
    dataset = "structure_media_assets_only"

    insert_media_schemas!(dataset, [%{name: "mediaAsset", title: "Media Asset", icon: "🖼"}])

    ws = create_workspace!()

    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(ws.id, %{"media" => %{"placement" => "main"}})

    # With only mediaAsset registered there is no "media-desk" wrapper —
    # the library link + asset list ride flat in the MAIN tier.
    tree = Structure.build(dataset, workspace_id: ws.id)
    library = Enum.find(tree.items, &(&1.id == "media-library"))

    assert library
    assert library.type == :plugin_link
    assert library.filter == "/studio/#{dataset}/media"
  end
end
