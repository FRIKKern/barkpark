defmodule BarkparkWeb.Contract.ExpandTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "ctest"
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      "ctest"
    )

    {:ok, _} = Content.create_document("author", %{"_id" => "ct-a1", "title" => "Jane"}, "ctest")
    {:ok, _} = Content.publish_document("ct-a1", "author", "ctest")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "ct-p1", "title" => "Hi", "author" => "ct-a1"},
        "ctest"
      )

    {:ok, _} = Content.publish_document("ct-p1", "post", "ctest")
    :ok
  end

  test "GET /v1/data/query/:ds/:type without expand returns raw ref ids", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi")
      |> json_response(200)

    assert post["author"] == "ct-a1"
  end

  test "GET /v1/data/query/:ds/:type?expand=true expands all reference fields", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi&expand=true")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["_id"] == "ct-a1"
    assert post["author"]["title"] == "Jane"
  end

  test "GET /v1/data/query/:ds/:type?expand=author expands only that field", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi&expand=author")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["title"] == "Jane"
  end

  test "GET /v1/data/doc/:ds/:type/:id?expand=true expands refs on single doc", %{conn: conn} do
    post =
      conn
      |> get("/v1/data/doc/ctest/post/ct-p1?expand=true")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["title"] == "Jane"
  end
end
