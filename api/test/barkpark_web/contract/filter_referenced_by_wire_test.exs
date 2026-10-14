defmodule BarkparkWeb.Contract.FilterReferencedByWireTest do
  @moduledoc """
  `filter[_id][referencedBy]=<type>` / `notReferencedBy` on `GET /v1/data/query`
  (task-f343d828861d7a7a). The resolved desk (`GET /v1/structure`) carries
  `{_id: {notReferencedBy: publication}}` on «Kategorier uten utgivelser», and the
  query door refused it, so an external Studio could not list what the desk
  declares. The door now accepts the two ops on `_id` for a caller that reads
  with a token; anonymous and public-read callers are still refused, because the
  clause looks at another type's rows (drafts included).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @ds "test"
  @token "barkpark-test-referenced-by-wire"

  setup do
    {:ok, _} = Auth.create_token(@token, "rw", @ds, ["read", "write"])

    for {name, fields} <- [
          {"category", [%{"name" => "title", "type" => "string"}]},
          {"publication",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "category", "type" => "reference", "to" => ["category"]}
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @ds
        )
    end

    for {type, id, content} <- [
          {"category", "cat-used", %{}},
          {"category", "cat-empty", %{}},
          {"publication", "pub-1", %{"category" => %{"_ref" => "cat-used"}}}
        ] do
      {:ok, _} =
        Content.create_document(type, %{"_id" => id, "title" => id, "content" => content}, @ds)

      {:ok, _} = Content.publish_document(id, type, @ds)
    end

    :ok
  end

  defp query(conn, qs, token) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, "/v1/data/query/#{@ds}/category?" <> qs)
  end

  defp ids(resp),
    do:
      resp
      |> json_response(200)
      |> get_in(["result", "documents"])
      |> Enum.map(& &1["_id"])
      |> Enum.sort()

  test "a token caller lists the categories with and without publications", %{conn: conn} do
    assert ids(query(conn, "filter[_id][referencedBy]=publication", @token)) == ["cat-used"]

    assert ids(query(scoped_conn(), "filter[_id][notReferencedBy]=publication", @token)) == [
             "cat-empty"
           ]
  end

  test "an unknown type is refused, not an empty list", %{conn: conn} do
    {400, _headers, body} =
      assert_error_sent(400, fn -> query(conn, "filter[_id][referencedBy]=nosuchtype", @token) end)

    assert body =~ "names no document type"
  end

  # task-d99d878b061b435a: a referencing type with a multi-type arrayOf field
  # answered a 500 HTML page. task-948233bb3443c675: several types, any type,
  # one field.
  test "a multi-type arrayOf on the referencing type, and the list, * and field forms",
       %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "page",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "sections",
              "type" => "arrayOf",
              "of" => [
                %{
                  "name" => "hero",
                  "type" => "composite",
                  "fields" => [
                    %{"name" => "category", "type" => "reference", "to" => ["category"]}
                  ]
                },
                %{
                  "name" => "text",
                  "type" => "composite",
                  "fields" => [%{"name" => "body", "type" => "string"}]
                }
              ]
            }
          ]
        },
        @ds
      )

    {:ok, _} =
      Content.create_document(
        "page",
        %{
          "_id" => "page-1",
          "title" => "page-1",
          "content" => %{
            "sections" => [%{"_type" => "hero", "category" => %{"_ref" => "cat-empty"}}]
          }
        },
        @ds
      )

    {:ok, _} = Content.publish_document("page-1", "page", @ds)

    assert ids(query(conn, "filter[_id][referencedBy]=page", @token)) == ["cat-empty"]

    assert ids(query(scoped_conn(), "filter[_id][referencedBy]=publication,page", @token)) ==
             ["cat-empty", "cat-used"]

    assert ids(query(scoped_conn(), "filter[_id][referencedBy]=*", @token)) ==
             ["cat-empty", "cat-used"]

    assert ids(query(scoped_conn(), "filter[_id][referencedBy]=publication.category", @token)) ==
             ["cat-used"]

    assert ids(query(scoped_conn(), "filter[_id][notReferencedBy]=page.sections", @token)) ==
             ["cat-used"]
  end

  test "an anonymous caller is still refused", %{conn: conn} do
    assert query(conn, "filter[_id][referencedBy]=publication", nil).status == 400
  end
end
