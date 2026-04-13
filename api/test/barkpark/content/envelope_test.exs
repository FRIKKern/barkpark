defmodule Barkpark.Content.EnvelopeTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  setup do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-1", "title" => "Hello", "content" => %{"body" => "hi", "tags" => ["a"]}},
        "test"
      )
    %{doc: doc}
  end

  test "renders flat envelope with reserved underscore keys", %{doc: doc} do
    env = Envelope.render(doc)
    assert env["_id"] == doc.doc_id
    assert env["_type"] == "post"
    assert env["_rev"] == doc.rev
    assert env["_draft"] == true
    assert env["_publishedId"] == "env-1"
    assert env["title"] == "Hello"
    assert env["body"] == "hi"
    assert env["tags"] == ["a"]
    assert is_binary(env["_createdAt"])
    assert String.ends_with?(env["_createdAt"], "Z")
  end

  test "no nested `content` key in output", %{doc: doc} do
    env = Envelope.render(doc)
    refute Map.has_key?(env, "content")
    refute Map.has_key?(env, :content)
  end

  test "user fields cannot override reserved keys" do
    {:ok, d} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-2", "title" => "X", "content" => %{"_id" => "HIJACK"}},
        "test"
      )
    env = Envelope.render(d)
    assert env["_id"] == d.doc_id
    refute env["_id"] == "HIJACK"
  end
end
