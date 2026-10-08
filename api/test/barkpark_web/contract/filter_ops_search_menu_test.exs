defmodule BarkparkWeb.Contract.FilterOpsSearchMenuTest do
  @moduledoc """
  The Sanity search-filter operators `/v1/data/query` could not express
  (task-aaf4d51bf8a51aec): a string "does not contain", an array "does not
  include", array length comparisons, and "references document".

    * `notContains` — case-insensitive; a document without the field counts as
      not containing it (Sanity's `!(field match …)`).
    * `nhas` — the array lacks the value (`_ref` or scalar); no array, no value.
    * `countEq countNeq countGt countGte countLt countLte` — array length; no
      array counts 0. The value must be an integer: anything else is a 400.
    * `filter[_references]=<id>` — the document references `id` anywhere in its
      content (`references(id)`).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, content} <- [
          {"m1",
           %{
             "excerpt" => "Short Excerpt",
             "tags" => [%{"_ref" => "tag-a"}, %{"_ref" => "tag-b"}],
             "seo" => %{"image" => %{"asset" => %{"_ref" => "image-1"}}}
           }},
          {"m2", %{"excerpt" => "Long read", "tags" => [%{"_ref" => "tag-c"}]}},
          {"m3", %{"tags" => []}}
        ] do
      {:ok, _} =
        Content.create_document("post", Map.merge(%{"_id" => id, "title" => "M"}, content), @ds)

      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    :ok
  end

  defp ids(conn, query) do
    %{"result" => body} =
      conn |> get("/v1/data/query/#{@ds}/post?filter[title]=M&" <> query) |> json_response(200)

    body["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()
  end

  test "notContains: case-insensitive, and a missing field does not contain", %{conn: conn} do
    assert ids(conn, "filter[excerpt][notContains]=excerpt") == ["m2", "m3"]
  end

  test "nhas: the array lacks the reference", %{conn: conn} do
    assert ids(conn, "filter[tags][nhas]=tag-a") == ["m2", "m3"]
  end

  test "array length comparisons", %{conn: conn} do
    assert ids(conn, "filter[tags][countEq]=2") == ["m1"]
    assert ids(conn, "filter[tags][countNeq]=1") == ["m1", "m3"]
    assert ids(conn, "filter[tags][countGt]=0") == ["m1", "m2"]
    assert ids(conn, "filter[tags][countGte]=1") == ["m1", "m2"]
    assert ids(conn, "filter[tags][countLt]=1") == ["m3"]
    assert ids(conn, "filter[tags][countLte]=1") == ["m2", "m3"]
  end

  test "a count op with a non-integer value is a 400", %{conn: conn} do
    resp = get(conn, "/v1/data/query/#{@ds}/post?filter[tags][countGt]=two")
    assert resp.status == 400
  end

  test "_references: the document references the id anywhere", %{conn: conn} do
    assert ids(conn, "filter[_references]=image-1") == ["m1"]
    assert ids(conn, "filter[_references]=tag-c") == ["m2"]
    assert ids(conn, "filter[_references]=nothing") == []
  end
end
