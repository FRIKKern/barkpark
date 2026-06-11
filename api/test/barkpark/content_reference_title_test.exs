defmodule Barkpark.ContentReferenceTitleTest do
  @moduledoc """
  Unit tests for `Barkpark.Content.reference_title/3` (Polish-3 Fix 4).

  `reference_title` resolves a stored reference VALUE (a plain doc-id string)
  to the referenced document's display title. With an EMPTY `ref_type` there
  is no type narrowing, so the same doc-id can match several rows (e.g. `p1`
  exists as both a `book` and a `post`). The resolver must:

    * NEVER raise `Ecto.MultipleResultsError` on a non-unique doc-id, and
    * return a single title, preferring the published row over a `drafts.` twin.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "ref_title_test"

  defp publish!(type, id, title) do
    {:ok, _} = Content.create_document(type, %{"_id" => id, "title" => title}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)
    :ok
  end

  describe "reference_title/3 with empty ref_type (no type narrowing)" do
    test "non-unique doc_id across two types returns one title and does NOT raise" do
      # Same published doc_id "p1" exists as both a post and a book.
      publish!("post", "p1", "Post One")
      publish!("book", "p1", "Book One")

      # Empty ref_type → no `d.type == ...` narrowing → both rows match the
      # doc_id clause. The old `Repo.one` would raise Ecto.MultipleResultsError
      # if the limit guard were dropped; `Repo.all |> List.first` never does.
      title = Content.reference_title("p1", "", @dataset)

      assert is_binary(title)
      assert title in ["Post One", "Book One"]
    end

    test "prefers the PUBLISHED row over its drafts. twin" do
      # Published row carries the canonical title; a draft twin exists with a
      # different (in-progress) title. The published row must win.
      {:ok, _} =
        Content.create_document("post", %{"_id" => "p2", "title" => "Published Title"}, @dataset)

      {:ok, _} = Content.publish_document("p2", "post", @dataset)
      # Editing the published doc spawns a fresh draft alongside it.
      {:ok, _} =
        Content.create_document("post", %{"_id" => "p2", "title" => "Draft Title"}, @dataset)

      assert Content.reference_title("p2", "", @dataset) == "Published Title"
    end

    test "falls back to the raw value when no document matches" do
      assert Content.reference_title("missing-id", "", @dataset) == "missing-id"
    end

    test "blank value returns empty string" do
      assert Content.reference_title("", "", @dataset) == ""
      assert Content.reference_title(nil, "", @dataset) == ""
    end
  end

  describe "reference_title/3 with a concrete ref_type" do
    test "narrows by type and resolves the title" do
      publish!("post", "p3", "The Post")
      publish!("book", "p3", "The Book")

      assert Content.reference_title("p3", "book", @dataset) == "The Book"
      assert Content.reference_title("p3", "post", @dataset) == "The Post"
    end
  end
end
