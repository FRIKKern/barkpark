defmodule BarkparkWeb.Contract.QueryFacetsTest do
  @moduledoc """
  task-8af256dcd8f17902 — `facet=` and `facet_range[field]=` on
  `GET /v1/data/query`: value counts and numeric buckets over the filtered
  set, not the page, in the same response. gyldendal.no counts format,
  language, contributors and price ranges over the current filter.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"
  @token "barkpark-test-query-facets"

  setup do
    Content.upsert_schema(
      %{"name" => "book", "title" => "Book", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, content} <- [
          {"fa-1",
           %{
             "format" => "pocket",
             "language" => ["nb", "en"],
             "price" => 99,
             "author" => %{"_ref" => "ada"}
           }},
          {"fa-2",
           %{
             "format" => "pocket",
             "language" => ["nb"],
             "price" => 199.5,
             "author" => %{"_ref" => "ada"}
           }},
          {"fa-3", %{"format" => "hardcover", "language" => ["nn", "nb", "nb"], "price" => 349}},
          {"fa-4", %{"format" => "ebook", "price" => "free", "author" => %{"_ref" => "bo"}}},
          {"fa-5", %{"format" => "hardcover", "language" => [], "price" => 500}}
        ] do
      {:ok, _} =
        Content.create_document(
          "book",
          Map.merge(%{"_id" => id, "title" => "Fa " <> id}, content),
          @ds
        )

      {:ok, _} = Content.publish_document(id, "book", @ds)
    end

    :ok
  end

  defp result(conn, query) do
    conn
    |> get(
      "/v1/data/query/#{@ds}/book?perspective=published&filter[title][startsWith]=Fa&" <> query
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp buckets(list), do: Map.new(list, &{&1["label"], &1["count"]})

  test "value counts cover the filtered set, not the page", %{conn: conn} do
    r = result(conn, "facet=format,language,author&limit=1")

    assert length(r["documents"]) == 1
    f = r["facets"]["fields"]
    assert buckets(f["format"]) == %{"pocket" => 2, "hardcover" => 2, "ebook" => 1}
    # An array counts each element once per document.
    assert buckets(f["language"]) == %{"nb" => 3, "en" => 1, "nn" => 1}
    # A reference counts its target id.
    assert buckets(f["author"]) == %{"ada" => 2, "bo" => 1}
    # Biggest first, ties by label.
    assert Enum.map(f["format"], & &1["label"]) == ["hardcover", "pocket", "ebook"]
  end

  test "facets follow the filter", %{conn: conn} do
    r = result(conn, "facet=format&filter[format][neq]=ebook&facet_range[price]=200")
    assert buckets(r["facets"]["fields"]["format"]) == %{"pocket" => 2, "hardcover" => 2}

    assert r["facets"]["ranges"]["price"] == [
             %{"from" => nil, "to" => 200, "count" => 2},
             %{"from" => 200, "to" => nil, "count" => 2}
           ]
  end

  test "range buckets list every bucket and skip non-numbers", %{conn: conn} do
    r = result(conn, "facet_range[price]=100,200.5,400,1000")

    assert r["facets"]["ranges"]["price"] == [
             %{"from" => nil, "to" => 100, "count" => 1},
             %{"from" => 100, "to" => 200.5, "count" => 1},
             %{"from" => 200.5, "to" => 400, "count" => 1},
             %{"from" => 400, "to" => 1000, "count" => 1},
             %{"from" => 1000, "to" => nil, "count" => 0}
           ]

    assert r["facets"]["fields"] == %{}
  end

  test "under drafts a document counts once, by its draft", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "book",
        %{"_id" => "fa-1", "title" => "Fa fa-1", "format" => "audiobook"},
        @ds
      )

    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "query-facets",
        @ds,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    # An anonymous read is pinned to published; drafts need a token.
    drafts =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get(
        "/v1/data/query/#{@ds}/book?perspective=drafts&filter[title][startsWith]=Fa&facet=format"
      )
      |> json_response(200)

    assert buckets(drafts["result"]["facets"]["fields"]["format"]) ==
             %{"audiobook" => 1, "pocket" => 1, "hardcover" => 2, "ebook" => 1}

    published = result(conn, "facet=format")
    assert buckets(published["facets"]["fields"]["format"])["pocket"] == 2
  end

  # `bp doc query --facet_range price:200 --facet_range format:1` sends the list form.
  test "the CLI's flat facet_range spelling reads the same", %{conn: conn} do
    flat = result(conn, "facet_range[]=price:200&facet_range[]=format:1")
    bracket = result(conn, "facet_range[price]=200&facet_range[format]=1")
    assert flat["facets"] == bracket["facets"]
  end

  test "no facet parameter, no facets key", %{conn: conn} do
    refute Map.has_key?(result(conn, "limit=2"), "facets")
  end

  test "a malformed facet or facet_range is a 400 naming the parameter", %{conn: conn} do
    for {q, param} <- [
          {"facet=a-b", "facet"},
          {"facet=" <> Enum.map_join(1..11, ",", &"f#{&1}"), "facet"},
          {"facet_range[price]=200,100", "facet_range"},
          {"facet_range[price]=abc", "facet_range"},
          {"facet_range=100", "facet_range"},
          {"facet_range[a.b]=1", "facet_range"},
          {"facet_range=price", "facet_range"},
          {"facet_range[]=price:1&facet_range[]=price:2", "facet_range"}
        ] do
      body = conn |> get("/v1/data/query/#{@ds}/book?" <> q) |> json_response(400)
      assert body["error"]["code"] == "malformed", q
      assert body["error"]["details"]["parameter"] == param, q
    end
  end
end
