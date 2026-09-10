defmodule Barkpark.StructureTreeAndMediaTest do
  @moduledoc """
  Gyldendal parity stage E3.3, the two desk affordances that had no seam
  (task-0944e8b4d066d55b criteria 2 and 3):

    * `{"kind":"tree"}` in the deskStructure document — Sanity's
      «Kategorier → Hierarkisk struktur»: the root pane lists the PARENTLESS
      documents of the type; opening one drills into a pane that shows that
      document on top (openable), a divider that carries the child count and
      the level, then its children — each drillable the same way, recursively.
      A child with unpublished edits renders ONCE.
    * `list_preview.media` names an image field; every desk row of that type
      carries the image's url as `:media` (nil when the document has none) and
      the pane marks that its rows have a media slot, so titles align.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "tree-media-#{System.unique_integer([:positive])}"

  defp schema!(name, title, fields, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{"name" => name, "title" => title, "visibility" => "public", "fields" => fields},
          extra
        ),
        @dataset
      )
  end

  defp doc!(type, id, title, content \\ %{}) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)
  end

  defp declare!(items) do
    schema!("deskStructure", "Desk", [%{"name" => "items", "type" => "object"}], %{
      "singleton" => true,
      "desk" => %{"hidden" => true}
    })

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  @tree_item %{
    "kind" => "tree",
    "id" => "hierarkisk-struktur",
    "title" => "Hierarkisk struktur",
    "icon" => "git-branch",
    "type" => "category",
    "parent" => "content.parent",
    "orderings" => [%{"field" => "title", "direction" => "asc"}]
  }

  setup do
    schema!("category", "Kategori", [
      %{"name" => "title", "title" => "Tittel", "type" => "string"},
      %{
        "name" => "parent",
        "title" => "Overordnet",
        "type" => "reference",
        "refType" => "category"
      }
    ])

    schema!(
      "publication",
      "Utgivelse",
      [
        %{"name" => "title", "title" => "Tittel", "type" => "string"},
        %{"name" => "cover", "title" => "Omslag", "type" => "image"}
      ],
      %{"list_preview" => %{"media" => "cover"}}
    )

    # Two roots, two children under A (one with a draft twin), one grandchild.
    doc!("category", "cat-b", "Bravo")
    doc!("category", "cat-a", "Alpha")
    doc!("category", "cat-a2", "Alpha two", %{"parent" => "cat-a"})
    doc!("category", "cat-a1", "Alpha one", %{"parent" => "cat-a"})
    doc!("category", "cat-a1x", "Alpha one x", %{"parent" => "cat-a1"})

    # An unpublished edit on cat-a1: the row must not double.
    {:ok, _} =
      Content.upsert_document(
        "category",
        %{
          "doc_id" => "cat-a1",
          "title" => "Alpha one (edited)",
          "content" => %{"parent" => "cat-a"}
        },
        @dataset
      )

    doc!("publication", "pub-with-cover", "With cover", %{
      "cover" => %{
        "assetId" => "a1",
        "url" => "/media/files/d/x/cover.jpg",
        "width" => 10,
        "height" => 10
      }
    })

    doc!("publication", "pub-no-cover", "No cover")

    declare!([
      %{
        "kind" => "documentTypeList",
        "id" => "alle",
        "type" => "publication",
        "title" => "Alle utgivelser"
      },
      %{
        "kind" => "list",
        "id" => "kategorier",
        "title" => "Kategorier",
        "items" => [
          @tree_item,
          %{
            "kind" => "documentTypeList",
            "id" => "alle-kategorier",
            "type" => "category",
            "title" => "Alle kategorier"
          }
        ]
      }
    ])

    :ok
  end

  defp tree_path, do: ["kategorier", "hierarkisk-struktur"]

  defp last_pane(path) do
    {panes, editor} = PaneBuilder.build(@dataset, path)
    {List.last(panes), editor}
  end

  defp row_titles(pane), do: for(%{type: :doc} = i <- pane.items, do: i.title)
  defp divider_labels(pane), do: for(%{type: :divider} = i <- pane.items, do: i.label)

  describe "tree" do
    test "the declared node is a type list of the PARENTLESS documents, carrying the tree spec" do
      tree = Structure.build(@dataset)
      kategorier = Enum.find(tree.items, &(&1.id == "kategorier"))
      node = Enum.find(kategorier.items, &(&1.id == "hierarkisk-struktur"))

      assert node, "the tree item is declared under Kategorier"
      assert node.type == :document_type_list and node.type_name == "category"
      assert node.filter == %{"content.parent" => %{"is" => "null"}}
      assert node.tree == %{"parent" => "content.parent"}
      assert node.orderings == [%{"field" => "title", "direction" => "asc"}]

      # …Rest must not resurrect a type the tree claimed.
      refute Enum.any?(
               tree.items,
               &(&1.id == "rest" and Enum.any?(&1.items, fn n -> n.type_name == "category" end))
             )
    end

    test "the root pane lists only the parentless documents in the declared order" do
      {pane, editor} = last_pane(tree_path())
      refute pane[:filter_error]
      assert row_titles(pane) == ["Alpha", "Bravo"]
      assert editor == nil
    end

    test "opening a root drills into parent-on-top, a counted divider, then the children — a draft twin once" do
      {pane, editor} = last_pane(tree_path() ++ ["cat-a"])
      assert editor == nil, "drilling a tree node opens a pane, not the editor"

      [first | _] = pane.items
      assert first.type == :doc and first.id == "cat-a" and first.title == "Alpha"

      assert divider_labels(pane) == ["Underkategorier (2) — Nivå 1"]

      assert row_titles(pane) == ["Alpha", "Alpha one (edited)", "Alpha two"],
             "children in title order, the edited child exactly once: " <> inspect(pane.items)

      ids = for %{type: :doc} = i <- pane.items, do: i.id
      assert ids == ["cat-a", "cat-a1", "cat-a2"], "rows carry PUBLISHED ids: " <> inspect(ids)
      assert Enum.find(pane.items, &(&1[:id] == "cat-a1")).is_draft
    end

    test "the parent row on top opens the editor for that document" do
      {pane, editor} = last_pane(tree_path() ++ ["cat-a", "cat-a"])
      assert pane[:selected] == "cat-a"
      assert editor && editor.type == "category"
      assert Content.published_id(editor.doc.doc_id) == "cat-a"
    end

    test "a child drills recursively; a leaf says it has no children" do
      {pane, editor} = last_pane(tree_path() ++ ["cat-a", "cat-a1"])
      assert editor == nil
      assert hd(pane.items).id == "cat-a1"
      assert divider_labels(pane) == ["Underkategorier (1) — Nivå 2"]
      assert row_titles(pane) == ["Alpha one (edited)", "Alpha one x"]

      {leaf, editor} = last_pane(tree_path() ++ ["cat-a", "cat-a1", "cat-a1x"])
      assert editor == nil
      assert hd(leaf.items).id == "cat-a1x"
      assert divider_labels(leaf) == ["Ingen underkategorier"]
      assert row_titles(leaf) == ["Alpha one x"]

      # Every tree pane stamps its own address so a row click appends to it.
      {panes, _} = PaneBuilder.build(@dataset, tree_path() ++ ["cat-a", "cat-a1", "cat-a1x"])
      assert List.last(panes).path == tree_path() ++ ["cat-a", "cat-a1", "cat-a1x"]
    end

    test "a segment that is not a child still opens as a document (never unreachable)" do
      {_pane, editor} = last_pane(tree_path() ++ ["cat-a", "cat-b"])
      assert editor && Content.published_id(editor.doc.doc_id) == "cat-b"
    end
  end

  describe "row media" do
    test "a list_preview.media field puts the image url on the row and marks the pane's media slot" do
      {pane, _} = last_pane(["alle"])
      with_cover = Enum.find(pane.items, &(&1.title == "With cover"))
      no_cover = Enum.find(pane.items, &(&1.title == "No cover"))

      assert with_cover.media == "/media/files/d/x/cover.jpg"
      assert with_cover.media_slot == true
      assert no_cover.media == nil

      assert no_cover.media_slot == true,
             "a row without an image still reserves the slot so titles align"
    end

    test "a type without a media declaration reserves no slot" do
      {pane, _} = last_pane(["kategorier", "alle-kategorier"])
      assert Enum.all?(pane.items, &(&1.media == nil and &1.media_slot == false))
    end
  end
end
