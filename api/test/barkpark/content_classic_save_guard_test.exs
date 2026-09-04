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
  use Barkpark.DataCase, async: true

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
        %{
          "id" => "b-title",
          "type" => "field-string",
          "fieldName" => "title",
          "value" => "Original Title"
        }
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
      form = %{
        "title" => "Updated Title",
        "slug" => "",
        "featuredImage" => "",
        "status" => "draft"
      }

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

    test "a submitted field with NO bound block persists as a plain content key" do
      id = "unbound-#{System.unique_integer([:positive])}"

      # A blocks-bearing doc whose block list binds ONLY title — featuredImage
      # has no bound block (the bug shape: the Studio image picker emitted the
      # value, the editor said "Saved", and the blocks branch dropped it).
      blocks = [
        %{
          "id" => "b-title",
          "type" => "field-string",
          "fieldName" => "title",
          "value" => "Unbound Test"
        },
        %{
          "id" => "free-p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Body."}]
        }
      ]

      content = Projection.project(%{"blocks" => blocks}, blocks)

      {:ok, base_doc} =
        Content.upsert_document(
          "post",
          %{"doc_id" => id, "title" => "Unbound Test", "content" => content},
          @dataset
        )

      image_value = ~s({"url":"/media/files/x.png","assetId":"asset-1"})

      form = %{
        "title" => "Unbound Test",
        "slug" => "",
        "featuredImage" => image_value,
        "status" => "draft"
      }

      {:ok, saved, _errs} = Content.upsert_draft(base_doc, "post", schema_for(), form, @dataset)

      # The unbound field landed as a plain content key; blocks survive intact.
      # Gyldendal parity E1: the picker's JSON wire string is DECODED at the save
      # boundary (Forms.coerce_field_value), so the key holds the object itself.
      assert saved.content["featuredImage"] == %{
               "url" => "/media/files/x.png",
               "assetId" => "asset-1"
             }

      assert Enum.map(saved.content["blocks"], & &1["id"]) == ["b-title", "free-p1"]

      # And a follow-up save with the field EMPTIED clears the key (the same
      # empty-string-clears semantics as the non-blocks branch).
      cleared_form = %{form | "featuredImage" => ""}

      {:ok, cleared, _errs} =
        Content.upsert_draft(saved, "post", schema_for(), cleared_form, @dataset)

      refute Map.has_key?(cleared.content, "featuredImage")
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

  describe "Beta block-op on a post — apply_document_block_op/5 (3.2)" do
    test "editing the bound title block persists + projects content[\"title\"] and the row title" do
      id = "beta-title-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "Before"},
          @dataset
        )

      title_block = Enum.find(doc.content["blocks"], &(&1["fieldName"] == "title"))

      op = %{
        "op" => "patch-block",
        "id" => title_block["id"],
        "patch" => %{"value" => "After (Beta)"}
      }

      {:ok, %{op_kind: "patch-block", block_id: bid}} =
        Content.apply_document_block_op(doc.doc_id, "post", op, @dataset)

      assert bid == title_block["id"]

      {:ok, saved} = Content.get_document(doc.doc_id, "post", @dataset)

      # Bound title block value + projected content["title"] + row title all moved.
      saved_title = Enum.find(saved.content["blocks"], &(&1["fieldName"] == "title"))
      assert saved_title["value"] == "After (Beta)"
      assert saved.content["title"] == "After (Beta)"
      assert saved.title == "After (Beta)"
    end

    test "editing the free body paragraph updates content[\"body\"] (doc.body)" do
      id = "beta-body-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "Body Test"},
          @dataset
        )

      free_para = Enum.find(doc.content["blocks"], &(not Projection.bound?(&1)))
      assert free_para["type"] == "paragraph"

      op = %{
        "op" => "patch-block",
        "id" => free_para["id"],
        "patch" => %{"content" => [%{"type" => "text", "value" => "Beta body text."}]}
      }

      {:ok, _} = Content.apply_document_block_op(doc.doc_id, "post", op, @dataset)

      {:ok, saved} = Content.get_document(doc.doc_id, "post", @dataset)

      saved_free = Enum.find(saved.content["blocks"], &(not Projection.bound?(&1)))
      assert saved_free["content"] == [%{"type" => "text", "value" => "Beta body text."}]

      # Projected body region reflects the edited free block + its rendered HTML.
      assert saved.content["body"]["blocks"] == [saved_free]
      assert saved.content["body"]["html"] =~ "Beta body text."
    end

    test "a Beta op on a legacy doc with NO blocks synthesizes-then-persists them" do
      id = "beta-synth-#{System.unique_integer([:positive])}"

      {:ok, base_doc} =
        Content.upsert_document(
          "post",
          %{"doc_id" => id, "title" => "Legacy Beta", "content" => %{"slug" => "legacy-beta"}},
          @dataset
        )

      refute Map.has_key?(base_doc.content, "blocks")

      # Resolve the in-memory synthesis to find the bound slug block id.
      {synth_blocks, true} = Content.resolve_blocks_for_edit(base_doc, "post", @dataset)
      slug_block = Enum.find(synth_blocks, &(&1["fieldName"] == "slug"))

      op = %{
        "op" => "patch-block",
        "id" => slug_block["id"],
        "patch" => %{"value" => "new-slug"}
      }

      {:ok, _} = Content.apply_document_block_op(base_doc.doc_id, "post", op, @dataset)

      {:ok, saved} = Content.get_document(base_doc.doc_id, "post", @dataset)

      # The first Beta edit MATERIALIZES content["blocks"] on disk + re-projects.
      assert is_list(saved.content["blocks"])
      assert saved.content["slug"] == "new-slug"
    end
  end

  describe "toggle losslessness (3 — Classic save after a Beta edit, 1 — flip is lossless)" do
    test "resolve_blocks_for_edit returns stored blocks verbatim (toggle does not mutate)" do
      id = "toggle-noop-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document("post", %{"doc_id" => id, "title" => "Toggle"}, @dataset)

      stored = doc.content["blocks"]

      # Resolving for a Beta open (the toggle's read) returns the SAME list,
      # synth? = false, no mutation — Classic and Beta read one block list.
      assert {^stored, false} = Content.resolve_blocks_for_edit(doc, "post", @dataset)
    end

    test "a Classic save after a Beta edit keeps the free body block intact" do
      id = "beta-then-classic-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document("post", %{"doc_id" => id, "title" => "Round Trip"}, @dataset)

      # Beta edit: write distinctive text into the free body paragraph.
      free_para = Enum.find(doc.content["blocks"], &(not Projection.bound?(&1)))

      beta_op = %{
        "op" => "patch-block",
        "id" => free_para["id"],
        "patch" => %{"content" => [%{"type" => "text", "value" => "Survives the Classic save."}]}
      }

      {:ok, _} = Content.apply_document_block_op(doc.doc_id, "post", beta_op, @dataset)
      {:ok, after_beta} = Content.get_document(doc.doc_id, "post", @dataset)

      after_beta_free = Enum.reject(after_beta.content["blocks"], &Projection.bound?/1)

      # Now a Classic save that only touches the title — the Exp-P3.1 guard,
      # exercised through the real Beta-then-Classic round trip.
      form = %{
        "title" => "Classic Edit",
        "slug" => "",
        "featuredImage" => "",
        "status" => "draft"
      }

      {:ok, saved, _errs} = Content.upsert_draft(after_beta, "post", schema_for(), form, @dataset)

      saved_free = Enum.reject(saved.content["blocks"], &Projection.bound?/1)

      # Free body block (the Beta-authored text) is byte-identical after Classic save.
      assert saved_free == after_beta_free
      assert saved.content["body"]["html"] =~ "Survives the Classic save."

      # And the Classic-edited title landed.
      assert saved.content["title"] == "Classic Edit"
    end
  end

  defp schema_for do
    {:ok, schema} = Content.get_schema("post", @dataset)
    schema
  end
end
