defmodule Barkpark.ContentFindReferencingDocsTest do
  @moduledoc """
  Behaviour lock for `find_referencing_docs/3` + `disconnect_references/3`
  after pushing the `content->>field == pub_id` predicate into SQL via the
  `:filter_map` eq op (barkpark-sji2).

  Previously each reference field triggered a full load-all-of-type followed
  by an in-memory `Enum.filter`. The DB now returns ONLY the referencing rows.
  These tests pin the OBSERVABLE contract: exactly the referencing docs are
  found and disconnected; a same-type non-referencing doc is untouched.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "find_ref_test"

  setup do
    # `article` carries a reference field pointing at an `author`.
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => []
      },
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [%{"name" => "author", "type" => "reference"}]
      },
      @dataset
    )

    {:ok, _} = Content.create_document("author", %{"_id" => "author-1", "title" => "Target"}, @dataset)
    {:ok, _} = Content.publish_document("author-1", "author", @dataset)

    # Two articles reference author-1; a third references someone else.
    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "art-ref-a", "title" => "Ref A", "author" => "author-1"},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "art-ref-b", "title" => "Ref B", "author" => "author-1"},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "art-other", "title" => "Other", "author" => "author-2"},
        @dataset
      )

    :ok
  end

  describe "find_referencing_docs/3" do
    test "returns exactly the docs whose reference field == the target id" do
      refs = Content.find_referencing_docs("author-1", @dataset)

      # Unpublished creates land under the `drafts.` prefix; the :raw
      # perspective returns those rows (same as the pre-SQL-filter code).
      ids = refs |> Enum.map(& &1.doc_id) |> Enum.sort()
      assert ids == ["drafts.art-ref-a", "drafts.art-ref-b"]

      # Shape unchanged: each match carries type + field + title.
      for ref <- refs do
        assert ref.type == "article"
        assert ref.field == "author"
        assert is_binary(ref.title)
      end
    end

    test "matches the published id even when called with the drafts. twin" do
      refs = Content.find_referencing_docs("drafts.author-1", @dataset)
      ids = refs |> Enum.map(& &1.doc_id) |> Enum.sort()
      assert ids == ["drafts.art-ref-a", "drafts.art-ref-b"]
    end

    test "no matches yields an empty list" do
      assert Content.find_referencing_docs("nobody-references-me", @dataset) == []
    end
  end

  describe "disconnect_references/3" do
    test "clears the reference field on exactly the referencing docs, untouched otherwise" do
      Content.disconnect_references("author-1", @dataset)

      {:ok, a} = Content.get_document("drafts.art-ref-a", "article", @dataset)
      {:ok, b} = Content.get_document("drafts.art-ref-b", "article", @dataset)
      {:ok, other} = Content.get_document("drafts.art-other", "article", @dataset)

      # The two referencing docs had their `author` field removed.
      refute Map.has_key?(a.content, "author")
      refute Map.has_key?(b.content, "author")

      # The non-referencing doc of the SAME type is untouched.
      assert other.content["author"] == "author-2"
    end

    test "after disconnect, find_referencing_docs returns nothing" do
      Content.disconnect_references("author-1", @dataset)
      assert Content.find_referencing_docs("author-1", @dataset) == []
    end
  end
end
