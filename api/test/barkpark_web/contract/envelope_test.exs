defmodule BarkparkWeb.Contract.EnvelopeTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    {:ok, _} = Content.create_document("post", %{"_id" => "e1", "title" => "A", "body" => "x"}, "test")
    {:ok, _} = Content.publish_document("e1", "post", "test")
    :ok
  end

  test "GET query/:ds/:type returns flat envelopes", %{conn: conn} do
    %{"documents" => [d | _]} =
      conn |> get("/v1/data/query/test/post") |> json_response(200)

    assert d["_id"] == "e1"
    assert d["_type"] == "post"
    assert d["_rev"]
    assert d["title"] == "A"
    assert d["body"] == "x"
    refute Map.has_key?(d, "content")
    refute Map.has_key?(d, "status")
  end
end
