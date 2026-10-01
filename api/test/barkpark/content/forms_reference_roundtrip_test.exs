defmodule Barkpark.Content.FormsReferenceRoundtripTest do
  @moduledoc """
  A stored reference keeps its stored SHAPE through a Classic save.

  Repro (Lane D, fresh local at e30529e07): `bp seed post` stores
  `author: {"_ref": "seed-author-3"}`. Opening "Title 3" in Classic, editing
  ONLY the title and publishing stored `author: "seed-author-3"` — the picker's
  hidden input carries the bare id, and the save wrote it. Starters read
  `post.author?._ref`, so the author page dropped the post.

  This does NOT decide the reference value contract (task-fcb752b43e11df9b,
  owner). It applies the rule the Classic save already follows for numbers,
  booleans, datetimes and selects: a field the user did not edit stays
  byte-identical, and an edited reference is written in the shape it was
  stored in.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Forms

  @dataset "production"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "author", "type" => "reference", "refType" => "author"}
    ]
  }

  defp seed!(author) do
    {:ok, doc} =
      Content.upsert_document(
        "post",
        %{
          "doc_id" => "drafts.ref-keep-#{System.unique_integer([:positive])}",
          "title" => "Title 3",
          "status" => "draft",
          "content" => %{"author" => author}
        },
        @dataset
      )

    doc
  end

  test "an untouched {_ref} reference stays byte-identical when another field is edited" do
    stored = %{"_ref" => "seed-author-3", "_type" => "reference"}
    doc = seed!(stored)

    # The picker's hidden input renders FieldInputs.reference_id/1 of the
    # stored value — the bare id — and posts it back untouched.
    assert BarkparkWeb.Components.FieldInputs.reference_id(stored) == "seed-author-3"
    params = %{"title" => "Title 3 edited", "author" => "seed-author-3"}

    assert {:ok, saved, _} = Forms.upsert_draft(doc, "post", @schema, params, @dataset)
    assert saved.title == "Title 3 edited"
    assert saved.content["author"] == stored, "an untouched reference must keep its {_ref} shape"
  end

  test "an EDITED reference is written in the shape it was stored in" do
    doc = seed!(%{"_ref" => "seed-author-3", "_type" => "reference"})
    params = %{"title" => "Title 3", "author" => "seed-author-1"}

    assert {:ok, saved, _} = Forms.upsert_draft(doc, "post", @schema, params, @dataset)
    assert saved.content["author"] == %{"_ref" => "seed-author-1", "_type" => "reference"}
  end

  describe "a block-backed (Beta-eligible) document" do
    setup do
      type = "refpost#{System.unique_integer([:positive])}"

      {:ok, schema} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Ref Post",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "author",
                "title" => "Author",
                "type" => "reference",
                "refType" => "author"
              }
            ],
            "layout" => [
              %{"kind" => "field", "name" => "title"},
              %{"kind" => "field", "name" => "author"}
            ]
          },
          @dataset
        )

      stored = %{"_ref" => "seed-author-3", "_type" => "reference"}

      {:ok, doc} =
        Content.create_document(
          type,
          %{"doc_id" => "ref-beta-1", "title" => "Title 3", "author" => stored},
          @dataset
        )

      %{type: type, schema: schema, stored: stored, doc: doc}
    end

    test "Classic: an untouched {_ref} survives a title edit", ctx do
      assert ctx.doc.content["author"] == ctx.stored
      assert is_list(ctx.doc.content["blocks"])

      params = %{"title" => "Title 3 edited", "author" => "seed-author-3"}
      assert {:ok, saved, _} = Forms.upsert_draft(ctx.doc, ctx.type, ctx.schema, params, @dataset)
      assert saved.content["author"] == ctx.stored
    end

    test "Beta: a patch-block on the title leaves the {_ref} untouched", ctx do
      title = Enum.find(ctx.doc.content["blocks"], &(&1["fieldName"] == "title"))

      assert {:ok, _} =
               Content.apply_document_block_op(
                 ctx.doc.doc_id,
                 ctx.type,
                 %{
                   "op" => "patch-block",
                   "id" => title["id"],
                   "patch" => %{"value" => "Beta edit"}
                 },
                 @dataset
               )

      {:ok, saved} = Content.get_document(ctx.doc.doc_id, ctx.type, @dataset)
      assert saved.content["title"] == "Beta edit"
      assert saved.content["author"] == ctx.stored
    end
  end

  test "a bare-string reference stays a bare string (no new contract)" do
    doc = seed!("seed-author-3")

    params = %{"title" => "Title 3 edited", "author" => "seed-author-3"}
    assert {:ok, saved, _} = Forms.upsert_draft(doc, "post", @schema, params, @dataset)
    assert saved.content["author"] == "seed-author-3"

    params = Map.put(params, "author", "seed-author-1")
    assert {:ok, saved, _} = Forms.upsert_draft(saved, "post", @schema, params, @dataset)
    assert saved.content["author"] == "seed-author-1"
  end
end
