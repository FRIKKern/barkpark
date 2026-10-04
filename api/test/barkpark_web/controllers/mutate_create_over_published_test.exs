defmodule BarkparkWeb.MutateCreateOverPublishedTest do
  @moduledoc """
  task-ab87d3e04f02021e: `create` over a PUBLISHED-only id (and, since owner
  ruling #41, `createIfNotExists`, which is now a no-op there).

  Found dogfooding bp: create {title, pages, genre}, publish, create again with
  only {title}, publish, and pages + genre were gone. The two verbs conflict
  only with an existing DRAFT (docs/api-v1.md), so over a published-only id
  they mint an EMPTY draft, and the next publish replaces the document with it.
  The contract stays as documented (no refusal). The response now carries a
  `create_over_published` warning naming the fields a publish would drop, so
  neither a script nor a person loses them blind.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @ds "test"
  @token "barkpark-test-create-over-published"

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "cop",
        @ds,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    :ok
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@ds}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp warnings(resp) do
    body = Jason.decode!(resp.resp_body)
    Enum.filter(body["warnings"] || [], &(&1["code"] == "create_over_published"))
  end

  defp publish_full!(id) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Dune", "content" => %{"pages" => 413, "genre" => "scifi"}},
        @ds
      )

    {:ok, _} = Content.publish_document(id, "post", @ds)
  end

  test "create over a published-only id WARNS and names the fields a publish would drop",
       %{conn: conn} do
    publish_full!("cop-1")

    resp = mutate(conn, [%{"create" => %{"_id" => "cop-1", "_type" => "post", "title" => "dup"}}])
    assert resp.status == 200, resp.resp_body

    assert [w] = warnings(resp)
    assert w["severity"] == "warning"
    assert w["message"] =~ ~s(PUBLISHED post "cop-1")
    assert w["message"] =~ "DROPS genre, pages"
    assert w["message"] =~ "bp doc patch post cop-1"
  end

  # Owner ruling #41 (task-e27126ee5e796e47): a published row occupies its id,
  # so createIfNotExists is a no-op there. It used to mint a fresh draft over
  # the live content, and the next publish replaced the page with it.
  test "createIfNotExists over a published-only id is a noop and writes no draft",
       %{conn: conn} do
    publish_full!("cop-2")

    resp =
      mutate(conn, [
        %{"createIfNotExists" => %{"_id" => "cop-2", "_type" => "post", "title" => "dup"}}
      ])

    assert resp.status == 200, resp.resp_body
    [result] = Jason.decode!(resp.resp_body)["results"]
    assert result["operation"] == "noop"
    assert result["id"] == "cop-2"
    assert result["document"]["title"] == "Dune"
    assert warnings(resp) == []

    assert {:error, :not_found} = Content.get_document("drafts.cop-2", "post", @ds)
    assert {:ok, live} = Content.get_document("cop-2", "post", @ds)
    assert live.title == "Dune"
    assert live.content["pages"] == 413
  end

  test "createIfNotExists on a published-only id honours ifRevisionID against the published row",
       %{conn: conn} do
    publish_full!("cop-rev")

    resp =
      mutate(conn, [
        %{
          "createIfNotExists" => %{
            "_id" => "cop-rev",
            "_type" => "post",
            "title" => "dup",
            "ifRevisionID" => "stale-rev"
          }
        }
      ])

    assert resp.status == 412, resp.resp_body
    assert {:error, :not_found} = Content.get_document("drafts.cop-rev", "post", @ds)
  end

  test "createIfNotExists naming drafts.<id> explicitly still creates that draft",
       %{conn: conn} do
    publish_full!("cop-explicit")

    resp =
      mutate(conn, [
        %{
          "createIfNotExists" => %{
            "_id" => "drafts.cop-explicit",
            "_type" => "post",
            "title" => "Dune",
            "pages" => 413,
            "genre" => "scifi"
          }
        }
      ])

    assert resp.status == 200, resp.resp_body
    [result] = Jason.decode!(resp.resp_body)["results"]
    assert result["operation"] == "create"
    assert result["id"] == "drafts.cop-explicit"
  end

  test "createIfNotExists on a fresh id creates the draft, and a repeat is a noop",
       %{conn: conn} do
    op = %{"createIfNotExists" => %{"_id" => "cop-fresh", "_type" => "post", "title" => "New"}}

    resp = mutate(conn, [op])
    assert resp.status == 200, resp.resp_body

    assert [%{"operation" => "create", "id" => "drafts.cop-fresh"}] =
             Jason.decode!(resp.resp_body)["results"]

    resp2 = mutate(conn, [op])
    assert [%{"operation" => "noop"}] = Jason.decode!(resp2.resp_body)["results"]
  end

  # task-b64beb44bafc6023: a create that carries every published field drops
  # nothing on publish, so it must not warn (it did, calling the draft EMPTY).
  test "a create over a published-only id that carries every field does NOT warn",
       %{conn: conn} do
    publish_full!("cop-full")

    resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => "cop-full",
            "_type" => "post",
            "title" => "Dune II",
            "pages" => 500,
            "genre" => "scifi"
          }
        }
      ])

    assert resp.status == 200, resp.resp_body
    assert warnings(resp) == []
  end

  test "a create over a fresh id carries no such warning", %{conn: conn} do
    resp =
      mutate(conn, [%{"create" => %{"_id" => "cop-fresh", "_type" => "post", "title" => "x"}}])

    assert resp.status == 200, resp.resp_body
    assert warnings(resp) == []
  end

  test "a create over an existing DRAFT is still the documented 409, with no warning",
       %{conn: conn} do
    assert mutate(conn, [%{"create" => %{"_id" => "cop-d", "_type" => "post", "title" => "a"}}]).status ==
             200

    resp = mutate(conn, [%{"create" => %{"_id" => "cop-d", "_type" => "post", "title" => "b"}}])
    assert resp.status == 409, resp.resp_body
    assert warnings(resp) == []
  end
end
