defmodule Barkpark.ContentClassicSaveGuardTest do
  @moduledoc """
  Exp-P3.1 + Exp-P3.2 (barkpark-ibsk) — the #1 invariant phase.

  Two things proven here, both against the DB:

    * **Create-from-Expectation (3.1)** — creating a post (an Expectation-bearing
      type) instantiates the Expectation into content["blocks"]: a BOUND block
      per layout field in order + the body region as free blocks, then projects
      content[fieldName] + content["body"].

    * **Classic-save data-loss guard (3.4, central)** — a Classic save of a
      block-bearing post that changes `title` updates content["title"] + the
      bound title block, while every FREE block and the block ORDER stay
      byte-identical. The save provably cannot drop or reorder free blocks.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Projection

  @dataset "production"

  setup do
    # The real `post` Expectation: title → slug → featuredImage → body region,
    # with a prefill scaffold (Exp-P1 shape).
    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "slug"},
            %{"kind" => "field", "name" => "featuredImage"},
            %{"kind" => "region", "name" => "body"}
          ],
          "prefill" => %{"status" => "draft", "featured" => false}
        },
        @dataset
      )

    {:ok, schema: schema}
  end

  describe "create-from-Expectation scaffold (3.1)" do
    test "a new post is scaffolded into ordered bound blocks + a body region, then projected" do
      id = "create-scaffold-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "Scaffolded Post"},
          @dataset
        )

      blocks = doc.content["blocks"]
      assert is_list(blocks)

      # One bound block per layout field, in layout order: title, slug,
      # featuredImage. Plus a trailing free body block (the region placeholder).
      bound = Enum.filter(blocks, &Projection.bound?/1)
      free = Enum.reject(blocks, &Projection.bound?/1)

      assert Enum.map(bound, & &1["fieldName"]) == ["title", "slug", "featuredImage"]
      assert Enum.map(bound, & &1["type"]) ==
               ["field-string", "field-slug", "field-image"]

      # Provided title wins for the bound title block; un-provided fields scaffold
      # empty (no prefill entry for slug/featuredImage).
      title_block = Enum.find(bound, &(&1["fieldName"] == "title"))
      assert title_block["value"] == "Scaffolded Post"
      assert Enum.find(bound, &(&1["fieldName"] == "slug"))["value"] == ""
      assert Enum.find(bound, &(&1["fieldName"] == "featuredImage"))["value"] == ""

      # Body region: a single empty paragraph placeholder.
      assert [%{"type" => "paragraph", "content" => []}] = Enum.map(free, &Map.drop(&1, ["id"]))

      # Projected index keys derive from the blocks.
      assert doc.content["title"] == "Scaffolded Post"
      assert doc.content["slug"] == ""
      assert doc.content["featuredImage"] == ""
      assert %{"blocks" => ^free, "html" => _} = doc.content["body"]
    end
  end

  describe "Classic-save data-loss guard (3.4 — central)" do
    test "saving title leaves the FREE blocks byte-identical and in order" do
      id = "guard-#{System.unique_integer([:positive])}"

      # A post WITH blocks: bound title + TWO free body blocks (the data at risk).
      free_blocks = [
        %{
          "id" => "free-p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "First free paragraph."}]
        },
        %{
          "id" => "free-p2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Second free paragraph."}]
        }
      ]

      blocks = [
        %{"id" => "b-title", "type" => "field-string", "fieldName" => "title", "value" => "Original Title"}
        | free_blocks
      ]

      content = Projection.project(%{"blocks" => blocks}, blocks)

      {:ok, base_doc} =
        Content.upsert_document(
          "post",
          %{"doc_id" => id, "title" => "Original Title", "content" => content},
          @dataset
        )

      # Snapshot the free blocks + their order BEFORE the Classic save.
      before_blocks = base_doc.content["blocks"]
      before_free = Enum.reject(before_blocks, &Projection.bound?/1)
      assert before_free == free_blocks

      # A Classic form save (the schema-form path → upsert_draft) that ONLY
      # changes the title field. The form map is flat — title + fields, no blocks.
      form = %{"title" => "Updated Title", "slug" => "", "featuredImage" => "", "status" => "draft"}

      {:ok, saved, _errs} = Content.upsert_draft(base_doc, "post", schema_for(), form, @dataset)

      saved_blocks = saved.content["blocks"]
      saved_free = Enum.reject(saved_blocks, &Projection.bound?/1)

      # (a) content["title"] + the bound title block value updated.
      assert saved.content["title"] == "Updated Title"

      saved_title_block = Enum.find(saved_blocks, &(&1["fieldName"] == "title"))
      assert saved_title_block["value"] == "Updated Title"

      # (b) the FREE blocks and their ORDER are byte-identical to before — the
      # save provably cannot drop or reorder free blocks.
      assert saved_free == before_free
      assert saved_free == free_blocks
      assert length(saved_blocks) == length(before_blocks)

      # The block list ORDER as a whole is preserved (title still first).
      assert Enum.map(saved_blocks, & &1["id"]) == Enum.map(before_blocks, & &1["id"])

      # content["body"] still reflects exactly the two free blocks.
      assert saved.content["body"]["blocks"] == free_blocks
    end

    test "a legacy doc WITHOUT blocks keeps the field-map save path" do
      id = "legacy-#{System.unique_integer([:positive])}"

      # No content["blocks"] — a classic field-map document.
      {:ok, base_doc} =
        Content.upsert_document(
          "post",
          %{"doc_id" => id, "title" => "Legacy", "content" => %{"slug" => "legacy"}},
          @dataset
        )

      refute Map.has_key?(base_doc.content, "blocks")

      form = %{"title" => "Legacy Updated", "slug" => "legacy-2", "status" => "draft"}
      {:ok, saved, _errs} = Content.upsert_draft(base_doc, "post", schema_for(), form, @dataset)

      # Old behavior: content rebuilt from the form map, no blocks introduced.
      refute Map.has_key?(saved.content, "blocks")
      assert saved.content["slug"] == "legacy-2"
    end
  end

  defp schema_for do
    {:ok, schema} = Content.get_schema("post", @dataset)
    schema
  end
end
