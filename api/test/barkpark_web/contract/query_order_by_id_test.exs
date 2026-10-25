defmodule BarkparkWeb.Contract.QueryOrderByIdTest do
  @moduledoc """
  task-7432da7989196de0 — `?order=_id:asc|desc` is accepted and sorts by the
  document id, the stable key a caller pages by (Sanity's `order(_id asc)`).
  It was refused (422): the order grammar took only names starting with a
  letter. `doc_id:` is the same; neither reads a content key of that name.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    # Created out of id order, so a created-at order would not pass for an id order.
    for id <- ~w(ord-c ord-a ord-b) do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => "Ord"}, @ds)
      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    :ok
  end

  defp ids(conn, order) do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/#{@ds}/post?filter[title]=Ord&order=#{order}")
      |> json_response(200)

    Enum.map(body["documents"], & &1["_id"])
  end

  test "_id:asc and _id:desc sort by the id", %{conn: conn} do
    assert ids(conn, "_id:asc") == ~w(ord-a ord-b ord-c)
    assert ids(conn, "_id:desc") == ~w(ord-c ord-b ord-a)
  end

  test "doc_id is the same column, and _id pages with an offset", %{conn: conn} do
    assert ids(conn, "doc_id:asc") == ~w(ord-a ord-b ord-c)

    %{"result" => page} =
      conn
      |> get("/v1/data/query/#{@ds}/post?filter[title]=Ord&order=_id:asc&limit=2&offset=1")
      |> json_response(200)

    assert Enum.map(page["documents"], & &1["_id"]) == ~w(ord-b ord-c)
  end

  test "_id with a collation sorts the same, uncollated", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/#{@ds}/post?filter[title]=Ord&order=_id:asc&collation=nb")
      |> json_response(200)

    assert Enum.map(body["documents"], & &1["_id"]) == ~w(ord-a ord-b ord-c)
  end
end
