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

  describe "papers in the desk (convergence: papers are documents)" do
    alias Barkpark.Content
    alias BarkparkWeb.Studio.PaneBuilder

    defp seed_paper_schema!(dataset) do
      insert_schema!(%{
        name: "paper",
        title: "Papers",
        icon: "📰",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "title" => "Title", "type" => "string"}]
      })
    end

    test "the paper schema yields a :document_type_list node in build/2" do
      dataset = "structure_test_papers"
      seed_legacy(dataset)
      seed_paper_schema!(dataset)

      tree = Structure.build(dataset)

      paper_node =
        Enum.find(tree.items, fn n ->
          n.type == :document_type_list and n.id == "paper"
        end)

      assert %Node{} = paper_node, "expected a paper doc-type-list node in top-level items"
      assert paper_node.type_name == "paper"
      assert paper_node.title == "Papers"
      assert paper_node.visibility == :public
    end

    test "a seeded paper is listed in the desk pane as a selectable :doc row" do
      dataset = "structure_test_papers_listed"
      seed_paper_schema!(dataset)

      slug = "2026-05-24-desk-listing"

      {:ok, _doc} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: dataset,
          blocks: [
            %{"id" => "h", "type" => "heading", "text" => "Desk Listing Paper"},
            %{"id" => "p", "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "body"}]}
          ]
        })

      # Drill into the "paper" doc-type-list pane (no slug → no editor yet).
      {panes, editor} = PaneBuilder.build(dataset, ["paper"])

      # No editor opens until a paper slug is selected.
      assert editor == nil

      paper_pane = List.last(panes)
      assert paper_pane.type_name == "paper"

      item = Enum.find(paper_pane.items, fn i -> i.id == slug end)
      assert item, "expected the seeded paper to be listed in the desk pane"
      # Rows are ordinary selectable :doc rows now — `phx-click="select"` drives
      # Studio-internal navigation to /studio/:dataset/paper/:slug. NOT an
      # external :paper_doc link out to /papers/:slug.
      assert item.type == :doc
      refute Map.has_key?(item, :href)
      # Title derived from the first heading block.
      assert item.title == "Desk Listing Paper"
    end

    test "selecting a paper opens a :paper view editor with the paper doc" do
      dataset = "structure_test_papers_editor"
      seed_paper_schema!(dataset)

      slug = "2026-05-24-paper-editor"

      {:ok, _doc} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: dataset,
          blocks: [
            %{"id" => "h", "type" => "heading", "text" => "Editor Paper"},
            %{"id" => "p", "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "body"}]}
          ]
        })

      # Drill into /studio/:dataset/paper/:slug.
      {panes, editor} = PaneBuilder.build(dataset, ["paper", slug])

      # The list pane stays present (desk structure visible)...
      paper_pane = List.last(panes)
      assert paper_pane.type_name == "paper"

      # ...and the editor resolves a :paper view carrying the paper document.
      assert editor[:view] == :paper
      assert editor[:type] == "paper"
      assert editor[:doc].doc_id == slug
      assert is_list(get_in(editor[:doc].content, ["blocks"]))
    end
  end

  describe "parse_filter/1" do
    test "returns empty map for nil" do
      assert Structure.parse_filter(nil) == %{}
    end

    test "returns empty map for empty string" do
      assert Structure.parse_filter("") == %{}
    end

    test "returns single-key map for field=value" do
      assert Structure.parse_filter("status=published") == %{"status" => "published"}
    end

    test "splits on first = only (preserves = in value)" do
      assert Structure.parse_filter("body=foo=bar") == %{"body" => "foo=bar"}
    end

    test "returns empty map for malformed input (no =)" do
      assert Structure.parse_filter("nonsense") == %{}
    end
  end
end
