defmodule Barkpark.StructureTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure
  alias Barkpark.Structure.Node

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  defp seed_legacy(dataset) do
    insert_schema!(%{
      name: "post",
      title: "Posts",
      icon: "file-text",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "page",
      title: "Pages",
      icon: "file",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "project",
      title: "Projects",
      icon: "briefcase",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "author",
      title: "Authors",
      icon: "user",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "category",
      title: "Categories",
      icon: "tag",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "siteSettings",
      title: "Site Settings",
      icon: "settings",
      visibility: "private",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "navigation",
      title: "Navigation",
      icon: "compass",
      visibility: "private",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "colors",
      title: "Colors",
      icon: "palette",
      visibility: "private",
      dataset: dataset,
      fields: []
    })
  end

  defp settings_node(tree) do
    Enum.find(tree.items, fn n -> n.type == :list and n.id == "settings" end)
  end

  describe "build/1" do
    test "surfaces book in the top-level nav and excludes it from Settings" do
      dataset = "structure_test_with_book"
      seed_legacy(dataset)

      insert_schema!(%{
        name: "book",
        title: "Book (ONIX 3.0)",
        icon: "book",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      book_node =
        Enum.find(tree.items, fn n ->
          n.type == :document_type_list and n.id == "book"
        end)

      assert %Node{} = book_node, "expected a book doc-type-list node in top-level items"
      assert book_node.type_name == "book"
      assert book_node.visibility == :public

      settings = settings_node(tree)
      assert %Node{} = settings, "expected a settings sub-list to still exist"

      refute Enum.any?(settings.items, fn n -> n.id == "book" end),
             "book must not also appear under Settings"
    end

    test "without book, tree contains only legacy groups and no stray dividers" do
      dataset = "structure_test_no_book"
      seed_legacy(dataset)

      tree = Structure.build(dataset)

      refute Enum.any?(tree.items, fn n ->
               n.type == :document_type_list and n.id == "book"
             end),
             "no book node expected when schema is absent"

      types = Enum.map(tree.items, & &1.type)

      refute List.first(types) == :divider, "no leading divider"
      refute List.last(types) == :divider, "no trailing divider"

      refute Enum.chunk_every(types, 2, 1, :discard)
             |> Enum.any?(fn pair -> pair == [:divider, :divider] end),
             "no consecutive dividers"
    end

    test "settings sub-list still surfaces siteSettings, navigation, and colors" do
      dataset = "structure_test_settings_regression"
      seed_legacy(dataset)

      tree = Structure.build(dataset)
      settings = settings_node(tree)

      assert %Node{} = settings
      ids = Enum.map(settings.items, & &1.id)

      assert "siteSettings" in ids
      assert "navigation" in ids
      assert "colors" in ids
    end
  end
end
