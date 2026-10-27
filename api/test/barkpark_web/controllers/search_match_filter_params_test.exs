defmodule BarkparkWeb.SearchMatchFilterParamsTest do
  @moduledoc """
  The search route's term rule, field filters, named facets and type-ahead
  fast path (tasks 3623955d22974d71, c7395e0d27e1121b, 7e7891dbf1f488ee):
  `match`, `filter[...]`, `facet` and `suggest` reach the retriever, the
  response says which rule ran, and a malformed value is a 400.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "search-match-filter-params-test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "displayName", "type" => "string"},
            %{"name" => "Format", "type" => "string"},
            %{"name" => "Language", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "Secret", "type" => "string", "private" => true}
          ]
        },
        @ds
      )

    for {id, name, format, lang} <- [
          {"m1", "Norsk grammatikk", "Lydbok", ["Bokmål"]},
          {"m2", "Norsk roman", "Heftet", ["Bokmål"]},
          {"m3", "Norsk dikt", "Lydbok", ["Nynorsk"]},
          {"m4", "Fransk grammatikk", "Heftet", ["Fransk"]}
        ] do
      {:ok, _} =
        Content.create_document(
          "book",
          %{
            "doc_id" => id,
            "content" => %{"displayName" => name, "Format" => format, "Language" => lang}
          },
          @ds
        )

      {:ok, _} = Content.publish_document(id, "book", @ds)
    end

    :ok
  end

  defp search(conn, params) do
    conn
    |> get("/v1/data/search/#{@ds}", Keyword.merge([type: "book", fields: "_id"], params))
  end

  test "every word must match by default, and the response says match: all", %{conn: conn} do
    body = conn |> search(q: "norsk grammatikk") |> json_response(200)
    assert body["count"] == 1
    assert body["match"] == "all"
    assert [%{"_id" => "m1"}] = body["documents"]
  end

  test "match=any matches any word and ranks the document with both first", %{conn: conn} do
    body = conn |> search(q: "norsk grammatikk", match: "any") |> json_response(200)
    assert body["count"] == 4
    assert body["match"] == "any"
    assert hd(body["documents"])["_id"] == "m1"
  end

  test "filter[...] narrows the count and facet counts field values", %{conn: conn} do
    body =
      conn
      |> search(q: "norsk", facet: "Language,Format", filter: %{"Format" => "Lydbok"})
      |> json_response(200)

    assert body["count"] == 2
    assert Enum.sort(Enum.map(body["documents"], & &1["_id"])) == ["m1", "m3"]
    langs = body["facets"]["fields"]["Language"]

    assert Enum.sort_by(langs, & &1["label"]) == [
             %{"label" => "Bokmål", "count" => 1},
             %{"label" => "Nynorsk", "count" => 1}
           ]

    assert body["facets"]["fields"]["Format"] == [%{"label" => "Lydbok", "count" => 2}]
  end

  test "suggest=true answers the same count without facets", %{conn: conn} do
    full = conn |> search(q: "norsk gram") |> json_response(200)
    fast = scoped_conn() |> search(q: "norsk gram", suggest: "true") |> json_response(200)
    assert fast["count"] == full["count"]
    assert hd(fast["documents"]) == hd(full["documents"])
    assert fast["facets"] == %{}
  end

  test "a malformed match, suggest or facet, or a filter without type, is a 400", %{conn: conn} do
    assert %{"error" => %{"code" => "malformed"}} =
             conn |> search(q: "norsk", match: "most") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             scoped_conn() |> search(q: "norsk", suggest: "maybe") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             scoped_conn() |> search(q: "norsk", facet: "a.b") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             scoped_conn()
             |> get("/v1/data/search/#{@ds}", q: "norsk", filter: %{"Format" => "Lydbok"})
             |> json_response(400)
  end

  test "an unknown filter operator is refused as on the query route", %{conn: conn} do
    resp = conn |> search(q: "norsk", filter: %{"Format" => %{"bogus" => "x"}})
    assert resp.status == 400
  end

  # task-5ddc3e08684f0d48: order= sorts the whole match by a field instead of
  # ranking it, with the query API's grammar.
  describe "order" do
    test "order=<field>:<dir> sorts the match, pages through it, and relevance is the default",
         %{conn: conn} do
      ids = fn params ->
        conn
        |> search(params)
        |> json_response(200)
        |> Map.fetch!("documents")
        |> Enum.map(& &1["_id"])
      end

      assert ids.(q: "norsk", order: "displayName:asc") == ["m3", "m1", "m2"]
      assert ids.(q: "norsk", order: "displayName:desc") == ["m2", "m1", "m3"]
      assert ids.(q: "norsk", order: "displayName:desc", limit: 1, offset: 1) == ["m1"]

      assert ids.(q: "norsk", order: "Format:asc,displayName:desc") == ["m2", "m1", "m3"]
      assert ids.(q: "norsk", order: "relevance") == ids.(q: "norsk")
    end

    test "the count and facets are those of the unsorted match", %{conn: conn} do
      body =
        conn
        |> search(q: "norsk", order: "displayName:asc", facet: "Format")
        |> json_response(200)

      assert body["count"] == 3
      assert Enum.map(body["facets"]["fields"]["Format"], & &1["count"]) |> Enum.sum() == 3
    end

    test "a bad order is refused, and order needs type", %{conn: conn} do
      assert conn |> search(q: "norsk", order: "displayName:sideways") |> json_response(422)

      body =
        conn
        |> get("/v1/data/search/#{@ds}", q: "norsk", order: "displayName:asc")
        |> json_response(400)

      assert body["error"]["message"] =~ "order needs type"
    end

    test "ordering by a field the caller may not read is forbidden_field", %{conn: conn} do
      body = conn |> search(q: "norsk", order: "Secret:asc") |> json_response(422)
      assert body["error"]["code"] == "forbidden_field"
      assert body["error"]["details"]["field"] == "Secret"
    end
  end

  # task-3bbf99d2bce8ee51: collapse=<field> keeps one hit per value.
  describe "collapse" do
    test "one hit per Format, the total counts groups, sizes ride in collapse", %{conn: conn} do
      body = conn |> search(q: "norsk", collapse: "Format") |> json_response(200)
      assert body["count"] == 2
      assert length(body["documents"]) == 2
      assert body["collapse"]["field"] == "Format"
      assert body["collapse"]["counts"] |> Map.values() |> Enum.sort() == [1, 2]
    end

    test "no collapse, no collapse key", %{conn: conn} do
      refute conn |> search(q: "norsk") |> json_response(200) |> Map.has_key?("collapse")
    end

    test "a bad name, a missing type or a private field is refused", %{conn: conn} do
      assert conn |> search(q: "norsk", collapse: "a-b") |> json_response(400)

      assert conn
             |> get("/v1/data/search/#{@ds}", q: "norsk", collapse: "Format")
             |> json_response(400)

      body = conn |> search(q: "norsk", collapse: "Secret") |> json_response(422)
      assert body["error"]["code"] == "forbidden_field"
    end
  end
end
