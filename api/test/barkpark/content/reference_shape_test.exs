defmodule Barkpark.Content.ReferenceShapeTest do
  @moduledoc """
  Owner ruling #42 (task-fcb752b43e11df9b): `{_ref}` is the canonical
  reference shape.

  Studio wrote a bare id (`"ada"`) while the typed SDK and both starters wrote
  `{"_ref": "ada"}`, which missed backlinks and let a delete leave dangling
  references. Studio now writes `{"_ref": id, "_type": "reference"}`; bare ids
  are still read everywhere and are rewritten on their next save, never in bulk.
  These tests load documents in BOTH shapes.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Forms
  alias Barkpark.Content.ShapeMigrations.BareReferences

  @ds "ref-shape"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "author", "type" => "reference", "refType" => "person"},
      %{"name" => "editors", "type" => "arrayOf", "of" => %{"type" => "reference"}}
    ]
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "rarticle", "title" => "Article", "visibility" => "public"}
        |> Map.put("fields", @schema.fields),
        @ds
      )

    {:ok, _} =
      Content.upsert_schema(%{"name" => "person", "title" => "Person", "fields" => []}, @ds)

    for id <- ["ada", "bob"] do
      {:ok, _} = Content.create_document("person", %{"doc_id" => id, "title" => id}, @ds)
      {:ok, _} = Content.publish_document(id, "person", @ds)
    end

    :ok
  end

  defp doc!(id, content) do
    {:ok, doc} =
      Content.create_document(
        "rarticle",
        %{"doc_id" => id, "title" => "Before", "content" => content},
        @ds
      )

    doc
  end

  defp save!(doc, params) do
    {:ok, saved, _} = Forms.upsert_draft(doc, "rarticle", @schema, params, @ds)
    saved
  end

  @ref_ada %{"_ref" => "ada", "_type" => "reference"}

  test "a Studio pick of a reference is written as {_ref}" do
    doc = doc!("rs-new", %{})
    saved = save!(doc, %{"title" => "Before", "author" => "ada"})
    assert saved.content["author"] == @ref_ada
  end

  test "a bare-id reference is rewritten as {_ref} on the next save, even untouched" do
    doc = doc!("rs-bare", %{"author" => "ada"})
    params = doc |> Forms.doc_to_form(@schema) |> Map.put("title", "After")

    # Tolerant read: the form shows the id for the bare shape.
    assert params["author"] == "ada"

    saved = save!(doc, params)
    assert saved.title == "After"
    assert saved.content["author"] == @ref_ada
  end

  test "an untouched {_ref} reference keeps its stored value byte for byte" do
    stored = %{"_ref" => "ada", "_type" => "reference", "_key" => "k1"}
    doc = doc!("rs-obj", %{"author" => stored})
    # The picker's hidden input posts the bare id it shows
    # (`FieldInputs.reference_id/1` reads the object).
    params =
      doc
      |> Forms.doc_to_form(@schema)
      |> Map.merge(%{"title" => "After", "author" => "ada"})

    assert save!(doc, params).content["author"] == stored
  end

  test "reference list rows are written as {_ref}" do
    doc = doc!("rs-list", %{})
    saved = save!(doc, %{"title" => "Before", "editors" => %{"0" => "ada", "1" => "bob"}})

    assert saved.content["editors"] == [
             @ref_ada,
             %{"_ref" => "bob", "_type" => "reference"}
           ]
  end

  test "backlinks read both shapes" do
    bare = doc!("rs-edge-bare", %{"author" => "ada"})
    obj = doc!("rs-edge-obj", %{"author" => @ref_ada})

    assert [%{to_id: "ada"}] = Content.extract_edges(bare)
    assert [%{to_id: "ada"}] = Content.extract_edges(obj)
  end

  test "the census counts bare ids; the dry run shows the next save and writes nothing" do
    doc!("rs-census-bare", %{"author" => "ada", "editors" => ["bob"]})
    doc!("rs-census-obj", %{"author" => @ref_ada})

    census = BareReferences.census()
    assert %{type: "rarticle", field: "author", documents: 1} in census
    assert %{type: "rarticle", field: "editors", documents: 1} in census

    rows = BareReferences.dry_run()
    row = Enum.find(rows, &(&1.doc_id == "drafts.rs-census-bare" and &1.field == "author"))
    assert row.to == @ref_ada
    refute Enum.any?(rows, &(&1.doc_id == "drafts.rs-census-obj"))

    assert {:ok, %{content: %{"author" => "ada"}}} =
             Content.get_document("drafts.rs-census-bare", "rarticle", @ds)
  end

  test "the field kind comes from the schema that governs the document" do
    # Same type name in another dataset, where `author` is a plain string.
    other = "ref-shape-plain"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "rarticle",
          "title" => "Article",
          "fields" => [%{"name" => "author", "type" => "string"}]
        },
        other
      )

    {:ok, _} =
      Content.create_document(
        "rarticle",
        %{"doc_id" => "rs-plain", "title" => "Plain", "content" => %{"author" => "Ada L."}},
        other
      )

    refute Enum.any?(BareReferences.dry_run(), &(&1.doc_id == "drafts.rs-plain"))
    BareReferences.run(apply: true)

    assert {:ok, %{content: %{"author" => "Ada L."}}} =
             Content.get_document("drafts.rs-plain", "rarticle", other)
  end

  test "run(apply: true) converts bare ids in both shapes and leaves {_ref} values alone" do
    bare = doc!("rs-apply-bare", %{"author" => "ada", "editors" => ["bob", @ref_ada]})
    obj = doc!("rs-apply-obj", %{"author" => Map.put(@ref_ada, "_key", "k1")})

    result = BareReferences.run(apply: true)
    assert result.applied?
    assert Enum.any?(result.rows, &(&1.doc_id == "drafts.rs-apply-bare"))

    {:ok, after_bare} = Content.get_document("drafts.rs-apply-bare", "rarticle", @ds)
    assert after_bare.content["author"] == @ref_ada

    assert after_bare.content["editors"] == [
             %{"_ref" => "bob", "_type" => "reference"},
             @ref_ada
           ]

    assert after_bare.rev != bare.rev

    {:ok, after_obj} = Content.get_document("drafts.rs-apply-obj", "rarticle", @ds)
    assert after_obj.content == obj.content
    assert after_obj.rev == obj.rev

    # Converted values still project the same backlinks.
    assert [_ | _] = Content.extract_edges(after_bare)
    assert BareReferences.census() |> Enum.filter(&(&1.type == "rarticle")) == []
  end

  describe "plugin-owned types keep their stored shape" do
    alias Barkpark.Content.CanonicalShapes

    test "FRT's types are exempt; a user type is not" do
      assert MapSet.member?(CanonicalShapes.exempt_types(), "ability")
      refute CanonicalShapes.canonical_write?("ability")
      assert CanonicalShapes.canonical_write?("rarticle")
    end

    test "a Studio save of a plugin-owned type keeps a bare-id reference; the convert skips it" do
      fields = [
        %{"name" => "title", "type" => "string"},
        %{"name" => "author", "type" => "reference"}
      ]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "ability", "title" => "Ability", "fields" => fields},
          @ds
        )

      {:ok, doc} =
        Content.create_document(
          "ability",
          %{"doc_id" => "rs-frt", "title" => "Before", "content" => %{"author" => "ada"}},
          @ds
        )

      {:ok, saved, _} =
        Forms.upsert_draft(
          doc,
          "ability",
          %{fields: fields},
          %{"title" => "After", "author" => "bob"},
          @ds
        )

      assert saved.content["author"] == "bob"

      assert Forms.build_content(%{"author" => "ada"}, %{name: "ability", fields: fields}) ==
               %{"author" => "ada"}

      refute Enum.any?(BareReferences.dry_run(), &(&1.doc_id == "drafts.rs-frt"))
    end
  end
end
