defmodule BarkparkWeb.MutateDeleteReferencedTest do
  @moduledoc """
  task-c8c22ee8076535fe — a `delete` mutation refuses a document that other
  documents still reference (409 `document_referenced`, referrers listed),
  as Sanity's API does. `"force": true` deletes anyway and is audited.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.{Content, Repo}
  alias Barkpark.Audit.Event

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
          %{"name" => "editor", "type" => "reference", "to" => [%{"type" => "author"}]}
        ]
      },
      @ds
    )

    {:ok, _} = Content.create_document("author", %{"doc_id" => "ann", "title" => "Ann"}, @ds)
    {:ok, _} = Content.publish_document("ann", "author", @ds)
    :ok
  end

  defp seed_post(id, content) do
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => id, "title" => id, "content" => content}, @ds)
  end

  defp delete_ann(conn, extra \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@ds}",
      Jason.encode!(%{
        "mutations" => [%{"delete" => Map.merge(%{"id" => "ann", "type" => "author"}, extra)}]
      })
    )
  end

  defp ann_exists?, do: match?({:ok, _}, Content.get_document("ann", "author", @ds))

  test "a top-level reference blocks the delete with 409 naming the referrer", %{conn: conn} do
    seed_post("p1", %{"author" => %{"_type" => "reference", "_ref" => "ann"}})

    resp = delete_ann(conn)
    assert resp.status == 409
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "document_referenced"
    assert body["error"]["details"]["id"] == "ann"
    assert body["error"]["details"]["referrers"] == [%{"id" => "drafts.p1", "type" => "post"}]
    assert ann_exists?()
  end

  test "a keyed reference inside an array or nested object also blocks", %{conn: conn} do
    seed_post("p2", %{"credits" => [%{"_key" => "k1", "_type" => "reference", "_ref" => "ann"}]})
    seed_post("p3", %{"seo" => %{"by" => %{"_ref" => "ann"}}})

    resp = delete_ann(conn)
    assert resp.status == 409
    ids = Enum.map(Jason.decode!(resp.resp_body)["error"]["details"]["referrers"], & &1["id"])
    assert ids == ["drafts.p2", "drafts.p3"]
  end

  test "a bare id in a schema-declared reference field blocks", %{conn: conn} do
    seed_post("p4", %{"editor" => "ann"})
    assert delete_ann(conn).status == 409
  end

  test "a _weak reference does not block", %{conn: conn} do
    seed_post("p5", %{"author" => %{"_ref" => "ann", "_weak" => true}})
    assert delete_ann(conn).status == 200
    refute ann_exists?()
  end

  test "a document with no referrers deletes as before", %{conn: conn} do
    seed_post("p6", %{"author" => %{"_ref" => "someone-else"}})
    assert delete_ann(conn).status == 200
    refute ann_exists?()
  end

  test "force: true deletes anyway and writes an audited override", %{conn: conn} do
    seed_post("p7", %{"author" => %{"_ref" => "ann"}})

    resp = delete_ann(conn, %{"force" => true})
    assert resp.status == 200
    refute ann_exists?()

    event =
      Repo.one!(
        from(e in Event,
          where: e.action == "document.delete_forced" and e.subject == "ann",
          order_by: [desc: e.occurred_at],
          limit: 1
        )
      )

    assert event.category == "content_mutation"
    assert event.metadata["referrers"] == ["post:drafts.p7"]
    assert event.metadata["referrer_count"] == 1
  end

  test "a missing target is still 404, even with dangling references to it", %{conn: conn} do
    seed_post("p8", %{"author" => %{"_ref" => "ghost"}})

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{@ds}",
        Jason.encode!(%{"mutations" => [%{"delete" => %{"id" => "ghost", "type" => "author"}}]})
      )

    assert resp.status == 404
  end

  test "a document referencing itself can be deleted", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "author",
        %{"doc_id" => "solo", "title" => "solo", "content" => %{"self" => %{"_ref" => "solo"}}},
        @ds
      )

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{@ds}",
        Jason.encode!(%{"mutations" => [%{"delete" => %{"id" => "solo", "type" => "author"}}]})
      )

    assert resp.status == 200
  end
end
