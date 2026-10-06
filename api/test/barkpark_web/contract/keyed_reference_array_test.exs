defmodule BarkparkWeb.Contract.KeyedReferenceArrayTest do
  @moduledoc """
  task-fb4c4703cc92b32e — an arrayOf-of-reference may hold Sanity-shaped items
  `{_key, _type: "reference", _ref}`. Written through /mutate and published,
  the items keep their `_key`, the edge projector indexes them, and the target's
  backlinks list the referencing document.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.Projector

  @ds "keyed_ref_array_test"

  setup do
    Barkpark.Auth.create_token(
      "keyed-ref-token",
      "dev",
      @ds,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    for name <- ["category", "post"] do
      fields =
        if name == "post",
          do: [
            %{
              "name" => "categories",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "category"}
            }
          ],
          else: []

      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
    end

    for id <- ["cat-a", "cat-b"] do
      {:ok, _} = Content.create_document("category", %{"_id" => id, "title" => id}, @ds)
      {:ok, _} = Content.publish_document(id, "category", @ds)
    end

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer keyed-ref-token")
    |> put_req_header("content-type", "application/json")
  end

  defp item(key, ref), do: %{"_key" => key, "_type" => "reference", "_ref" => ref}

  test "keyed reference items keep their _key and still index as backlinks", %{conn: conn} do
    items = [item("k1", "cat-a"), item("k2", "cat-b")]

    body = %{
      "mutations" => [
        %{
          "create" => %{
            "_id" => "post-1",
            "_type" => "post",
            "title" => "P",
            "categories" => items
          }
        },
        %{"publish" => %{"id" => "post-1", "type" => "post"}}
      ]
    }

    assert conn
           |> authed()
           |> post("/v1/data/mutate/#{@ds}", Jason.encode!(body))
           |> Map.get(:status) ==
             200

    {:ok, published} = Content.get_document("post-1", "post", @ds)
    assert published.content["categories"] == items

    assert {:ok, %{added: 2}} = Projector.upsert_record(published)

    resp = scoped_conn() |> authed() |> get("/v1/data/backlinks/#{@ds}/cat-a")
    assert resp.status == 200
    links = Jason.decode!(resp.resp_body)["result"]["backlinks"]
    assert [%{"from_doc_id" => "post-1", "via_field" => "categories"}] = links
  end
end
