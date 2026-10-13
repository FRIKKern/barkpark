defmodule BarkparkWeb.DisconnectControllerTest do
  @moduledoc """
  `POST /v1/data/disconnect/:dataset/:doc_id` (task-0bc05ce5cdefd8dc): a member
  token removes every reference to a document over HTTP — scalar and arrayOf —
  and learns which documents and fields changed. Narrowed callers are refused.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.DisconnectController

  @ds "test"
  @token "barkpark-test-disconnect-http"

  setup do
    {:ok, _} = Auth.create_token(@token, "rw", @ds, ["read", "write"])

    for {name, fields} <- [
          {"category", [%{"name" => "title", "type" => "string"}]},
          {"publication",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "category", "type" => "reference", "to" => ["category"]},
             %{
               "name" => "extra",
               "type" => "arrayOf",
               "of" => %{"type" => "reference", "to" => ["category"]}
             }
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @ds
        )
    end

    for {type, id, content} <- [
          {"category", "cat-1", %{}},
          {"publication", "pub-a", %{"category" => %{"_ref" => "cat-1"}}},
          {"publication", "pub-b", %{"extra" => [%{"_ref" => "cat-1"}, %{"_ref" => "cat-2"}]}}
        ] do
      {:ok, _} =
        Content.create_document(type, %{"_id" => id, "title" => id, "content" => content}, @ds)

      {:ok, _} = Content.publish_document(id, type, @ds)
    end

    :ok
  end

  test "a member token disconnects every reference and learns what changed", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> post("/v1/data/disconnect/#{@ds}/cat-1")
      |> json_response(200)

    changed = Map.new(body["disconnected"], &{&1["id"], &1["fields"]})
    assert changed["pub-a"] == ["category"]
    assert changed["pub-b"] == ["extra"]

    {:ok, a} = Content.get_document("pub-a", "publication", @ds)
    {:ok, b} = Content.get_document("pub-b", "publication", @ds)
    refute Map.has_key?(a.content, "category")
    assert b.content["extra"] == [%{"_ref" => "cat-2"}]
  end

  test "no token is refused", %{conn: conn} do
    resp = post(conn, "/v1/data/disconnect/#{@ds}/cat-1")
    assert resp.status in [401, 403]
  end

  test "a grant-narrowed or share-link caller is refused" do
    assert DisconnectController.narrowed?(%{grant_scoped_read: true})
    assert DisconnectController.narrowed?(%{share_writer: true})
    refute DisconnectController.narrowed?(%{})
  end

  # A schema that declares `of` Sanity-style (a list of element types) crashed
  # every disconnect in this dataset, the Studio's unpublish guard included.
  test "a list-shaped arrayOf schema in the dataset does not crash it", %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "listshaped",
          "title" => "listshaped",
          "visibility" => "public",
          "fields" => [
            %{"name" => "refs", "type" => "arrayOf", "of" => [%{"type" => "reference"}]}
          ]
        },
        @ds
      )

    assert conn
           |> put_req_header("authorization", "Bearer " <> @token)
           |> post("/v1/data/disconnect/#{@ds}/cat-1")
           |> json_response(200)
  end
end
