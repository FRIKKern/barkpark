defmodule BarkparkWeb.MutateCreateOverPublishedTest do
  @moduledoc """
  task-ab87d3e04f02021e: `create` / `createIfNotExists` over a PUBLISHED-only id.

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

  test "createIfNotExists over a published-only id warns too", %{conn: conn} do
    publish_full!("cop-2")

    resp =
      mutate(conn, [
        %{"createIfNotExists" => %{"_id" => "cop-2", "_type" => "post", "title" => "dup"}}
      ])

    assert resp.status == 200, resp.resp_body
    assert [w] = warnings(resp)
    assert w["message"] =~ "createIfNotExists minted an EMPTY draft"
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
