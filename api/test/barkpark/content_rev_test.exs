defmodule Barkpark.ContentRevTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  test "create_document stamps a rev" do
    {:ok, doc} = Content.create_document("post", %{"doc_id" => "rev-1", "title" => "T"}, "test")
    assert is_binary(doc.rev) and byte_size(doc.rev) >= 16
  end

  test "updating a doc produces a new rev" do
    {:ok, d1} = Content.create_document("post", %{"doc_id" => "rev-2", "title" => "A"}, "test")
    {:ok, d2} = Content.upsert_document("post", %{"doc_id" => d1.doc_id, "title" => "B"}, "test")
    refute d1.rev == d2.rev
  end
end
