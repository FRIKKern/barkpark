defmodule Barkpark.Content.EdgesRefObjectTest do
  @moduledoc """
  task-37ee0fed8f9b0de1 — a reference stored as a Sanity-style `{"_ref": id}`
  object is READ like a bare id by every edge reader.

  On main, `extract_field_edges/2` kept only binary values, so an article whose
  `author` is `{"_ref": "ada"}` projected no `content_edges` row: backlinks
  answered 0 and the Studio unpublish/delete guard (which probes
  `Content.Graph.reverse_referencers/2` over that table) let `ada` be removed
  with no warning. `find_referencing_docs/3` (the disconnect's scalar scan)
  and the disconnect strip had the same bare-id-only gap.

  CONTRACT-NEUTRAL: which shape is canonical is an open owner ruling. These
  tests pin only that both shapes are READ the same; nothing here changes what
  is stored or how a field is typed.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Edges
  alias Barkpark.EdgeProjector.Projector

  @dataset "edges_ref_object_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Article",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "person"},
            %{
              "name" => "editors",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "person"}
            }
          ]
        },
        @dataset
      )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp ref(id), do: %{"_ref" => id, "_type" => "reference"}

  defp shape(edges),
    do: edges |> Enum.map(&Map.delete(&1, :from_id)) |> Enum.sort_by(&{&1.field, &1.to_id})

  describe "extract_edges/2" do
    test "a {_ref} scalar reference emits the same edge as the bare id" do
      publish!("person", "ada")
      bare = publish!("article", "a-bare", %{"author" => "ada"})
      obj = publish!("article", "a-obj", %{"author" => ref("ada")})

      obj_edges = Content.extract_edges(obj)

      assert [%{from_id: "a-obj", to_id: "ada", field: "author", dangling: false}] = obj_edges
      assert shape(obj_edges) == shape(Content.extract_edges(bare))
    end

    test "an arrayOf-of-reference emits one edge per element, whichever shape" do
      publish!("person", "ada")
      publish!("person", "bob")
      # The empty `ref("")` row cannot be published since owner ruling #47
      # (publish refuses empty list rows), so the walker reads the draft.
      {:ok, src} =
        Content.create_document(
          "article",
          %{"_id" => "a-arr", "title" => "a-arr", "editors" => ["ada", ref("bob"), ref(""), 7]},
          @dataset
        )

      assert src |> Content.extract_edges() |> Enum.map(& &1.to_id) |> Enum.sort() ==
               ["ada", "bob"]
    end

    test "a {_ref} to a missing target is dangling, like a bare id" do
      src = publish!("article", "a-ghost", %{"author" => ref("ghost")})
      assert [%{to_id: "ghost", dangling: true}] = Content.extract_edges(src)
    end
  end

  test "reference_target/1 reads both shapes and nothing else" do
    assert Edges.reference_target("ada") == "ada"
    assert Edges.reference_target(ref("ada")) == "ada"
    assert Edges.reference_target(%{"_ref" => ""}) == nil
    assert Edges.reference_target("") == nil
    assert Edges.reference_target(%{"id" => "ada"}) == nil
    assert Edges.reference_target(nil) == nil
  end

  test "the projected edge reaches reverse_referencers — the unpublish/delete guard's probe" do
    publish!("person", "ada")
    src = publish!("article", "a-guard", %{"author" => ref("ada")})

    assert {:ok, %{added: 1}} = Projector.upsert_record(src)

    assert [%{from_doc_id: "a-guard", via_field: "author"}] =
             Content.Graph.reverse_referencers("ada", dataset: @dataset)
  end

  test "find_referencing_docs/3 finds a {_ref} scalar referencer" do
    publish!("person", "ada")
    publish!("article", "a-scan-bare", %{"author" => "ada"})
    publish!("article", "a-scan-obj", %{"author" => ref("ada")})

    ids = "ada" |> Content.find_referencing_docs(@dataset) |> Enum.map(& &1.doc_id)
    assert Enum.sort(Enum.uniq(ids)) == ["a-scan-bare", "a-scan-obj"]
  end

  test "disconnect_references/3 strips the {_ref} shape and keeps other references" do
    publish!("person", "ada")
    publish!("person", "bob")

    src =
      publish!("article", "a-strip", %{"author" => ref("ada"), "editors" => [ref("ada"), "bob"]})

    {:ok, _} = Projector.upsert_record(src)

    Content.disconnect_references("ada", @dataset)

    {:ok, doc} = Content.get_document("a-strip", "article", @dataset)
    refute Map.has_key?(doc.content, "author")
    assert doc.content["editors"] == ["bob"]
  end
end
