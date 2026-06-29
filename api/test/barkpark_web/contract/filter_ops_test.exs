defmodule BarkparkWeb.Contract.FilterOpsTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops_http"
    )

    for {id, title} <- [{"f1", "Alpha"}, {"f2", "Beta"}, {"f3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, "fops_http")
      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    :ok
  end

  test "filter[title][eq]=Alpha matches one", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Beq%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "Alpha"
  end

  test "filter[title][in]=Alpha,Gamma matches two", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D=Alpha,Gamma")
      |> json_response(200)

    assert body["count"] == 2
    titles = Enum.map(body["documents"], & &1["title"]) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "filter[title][contains]=a is case-insensitive", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bcontains%5D=a")
      |> json_response(200)

    assert body["count"] == 3
  end

  test "bare filter[title]=Alpha still works (sugar for eq)", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
  end

  test "scalar `field is null` / `is not null` filter (CLI/raw-API form)", %{conn: conn} do
    # f1/f2/f3 have no `category`; f4 does.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "f4", "title" => "Delta", "category" => "x"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("f4", "post", "fops_http")

    is_null =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is null")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_null["documents"], & &1["title"]) |> Enum.sort() ==
             ["Alpha", "Beta", "Gamma"]

    is_not_null =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is not null")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_not_null["documents"], & &1["title"]) == ["Delta"]
  end
end
