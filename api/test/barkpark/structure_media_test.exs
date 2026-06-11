defmodule Barkpark.StructureMediaTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure

  test "build/1 includes Media group when media schemas are registered" do
    dataset = "structure_media_test"

    for spec <- [
          %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
          %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
        ] do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(
        Map.merge(spec, %{visibility: "private", dataset: dataset, fields: []})
      )
      |> Repo.insert!()
    end

    tree = Structure.build(dataset)
    media_node = Enum.find(tree.items, &(&1.id == "media-desk"))

    assert media_node
    assert media_node.title == "Media"

    child_titles = Enum.map(media_node.items, & &1.title)
    assert "Media Library" in child_titles

    child_names = Enum.map(media_node.items, & &1.type_name)
    assert "mediaAsset" in child_names
    assert "mediaCollection" in child_names
  end

  test "build/1 includes Media Library link when only mediaAsset schema exists" do
    dataset = "structure_media_assets_only"

    %SchemaDefinition{}
    |> SchemaDefinition.changeset(%{
      name: "mediaAsset",
      title: "Media Asset",
      icon: "🖼",
      visibility: "private",
      dataset: dataset,
      fields: []
    })
    |> Repo.insert!()

    tree = Structure.build(dataset)
    library = Enum.find(tree.items, &(&1.id == "media-library"))

    assert library
    assert library.type == :plugin_link
    assert library.filter == "/studio/#{dataset}/media"
  end
end
