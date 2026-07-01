defmodule Barkpark.Search.DocumentsRetrieverPerspectiveTest do
  # Pure, DB-free: builds the Ecto query struct and asserts the perspective
  # filter fails CLOSED. No repo/DB — we compare the `wheres` on the query.
  use ExUnit.Case, async: true

  import Ecto.Query
  alias Barkpark.Search.DocumentsRetriever

  defp base, do: from(d in "documents")

  test ":published applies exactly one (drafts-excluding) where clause" do
    q = DocumentsRetriever.perspective_filter(base(), :published)
    assert length(q.wheres) == 1
  end

  test ":drafts applies exactly one (drafts-only) where clause" do
    q = DocumentsRetriever.perspective_filter(base(), :drafts)
    assert length(q.wheres) == 1
  end

  test ":raw (explicit atom) returns the query UNFILTERED" do
    q = DocumentsRetriever.perspective_filter(base(), :raw)
    assert q.wheres == []
  end

  test "fail-closed: a STRING perspective filters to published, not unfiltered" do
    published = DocumentsRetriever.perspective_filter(base(), :published)
    from_string = DocumentsRetriever.perspective_filter(base(), "published")
    assert inspect(from_string.wheres) == inspect(published.wheres)
    assert from_string.wheres != []
  end

  test "fail-closed: an unknown atom filters to published, not unfiltered" do
    published = DocumentsRetriever.perspective_filter(base(), :published)
    bogus = DocumentsRetriever.perspective_filter(base(), :bogus)
    assert inspect(bogus.wheres) == inspect(published.wheres)
    assert bogus.wheres != []
  end

  test "fail-closed: nil filters to published" do
    published = DocumentsRetriever.perspective_filter(base(), :published)
    from_nil = DocumentsRetriever.perspective_filter(base(), nil)
    assert inspect(from_nil.wheres) == inspect(published.wheres)
  end
end
