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
            %{"name" => "Language", "type" => "arrayOf", "of" => %{"type" => "string"}}
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
    fast = build_conn() |> search(q: "norsk gram", suggest: "true") |> json_response(200)
    assert fast["count"] == full["count"]
    assert hd(fast["documents"]) == hd(full["documents"])
    assert fast["facets"] == %{}
  end

  test "a malformed match, suggest or facet, or a filter without type, is a 400", %{conn: conn} do
    assert %{"error" => %{"code" => "malformed"}} =
             conn |> search(q: "norsk", match: "most") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             build_conn() |> search(q: "norsk", suggest: "maybe") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             build_conn() |> search(q: "norsk", facet: "a.b") |> json_response(400)

    assert %{"error" => %{"code" => "malformed"}} =
             build_conn()
             |> get("/v1/data/search/#{@ds}", q: "norsk", filter: %{"Format" => "Lydbok"})
             |> json_response(400)
  end

  test "an unknown filter operator is refused as on the query route", %{conn: conn} do
    resp = conn |> search(q: "norsk", filter: %{"Format" => %{"bogus" => "x"}})
    assert resp.status == 400
  end
end
