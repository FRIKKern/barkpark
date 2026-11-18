defmodule BarkparkWeb.MutateDeleteWeakReferenceTest do
  @moduledoc """
  task-a2454829afff0795 — a `{"_ref", "_weak": true}` value does not block
  deleting its target, also when it sits in a field the schema declares as
  `reference` and the referrer is published. A strong reference in the same
  field still blocks.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "test"

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @ds
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "editor", "type" => "reference", "to" => [%{"type" => "author"}]},
          %{
            "name" => "credits",
            "type" => "array",
            "of" => [%{"type" => "reference", "to" => [%{"type" => "author"}]}]
          },
          %{
            "name" => "seo",
            "type" => "object",
            "fields" => [
              %{"name" => "by", "type" => "reference", "to" => [%{"type" => "author"}]}
            ]
          }
        ]
      },
      @ds
    )

    for id <- ["ann", "bea"] do
      {:ok, _} = Content.create_document("author", %{"doc_id" => id, "title" => id}, @ds)
      {:ok, _} = Content.publish_document(id, "author", @ds)
    end

    :ok
  end

  defp publish_post(id, content) do
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => id, "title" => id, "content" => content}, @ds)

    {:ok, _} = Content.publish_document(id, "post", @ds)
  end

  defp weak(id), do: %{"_type" => "reference", "_ref" => id, "_weak" => true}

  defp delete_authors(conn, ids) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@ds}",
      Jason.encode!(%{
        "mutations" => Enum.map(ids, &%{"delete" => %{"id" => &1, "type" => "author"}})
      })
    )
  end

  defp exists?(id), do: match?({:ok, _}, Content.get_document(id, "author", @ds))

  test "a weak reference in a schema reference field does not block the delete", %{conn: conn} do
    publish_post("p1", %{"editor" => weak("ann")})

    assert delete_authors(conn, ["ann"]).status == 200
    refute exists?("ann")

    {:ok, post} = Content.get_document("p1", "post", @ds)
    assert post.content["editor"]["_ref"] == "ann"
    assert post.content["editor"]["_weak"] == true
  end

  test "weak references in an array of references and in a nested object do not block",
       %{conn: conn} do
    publish_post("p2", %{"credits" => [Map.put(weak("ann"), "_key", "k1")]})
    publish_post("p3", %{"seo" => %{"by" => weak("ann")}})

    assert delete_authors(conn, ["ann"]).status == 200
    refute exists?("ann")
  end

  test "a run of deletes (the batched check) lets weak schema references through",
       %{conn: conn} do
    publish_post("p4", %{"editor" => weak("ann")})
    publish_post("p5", %{"editor" => weak("bea")})

    assert delete_authors(conn, ["ann", "bea"]).status == 200
    refute exists?("ann")
    refute exists?("bea")
  end

  test "a strong reference in the same schema field still blocks", %{conn: conn} do
    publish_post("p6", %{"editor" => %{"_type" => "reference", "_ref" => "ann"}})

    resp = delete_authors(conn, ["ann"])
    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "document_referenced"
    assert exists?("ann")

    resp = delete_authors(conn, ["ann", "bea"])
    assert resp.status == 409
    assert exists?("ann")
  end
end
