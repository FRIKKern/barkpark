defmodule Barkpark.ContentFlatTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  test "create accepts flat envelope and round-trips through render" do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"_id" => "flat-1", "title" => "T", "body" => "hi", "tags" => ["a", "b"]},
        "test"
      )

    env = Envelope.render(doc)
    assert env["body"] == "hi"
    assert env["tags"] == ["a", "b"]
  end
end
