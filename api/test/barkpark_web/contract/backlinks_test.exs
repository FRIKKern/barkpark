defmodule BarkparkWeb.Contract.BacklinksTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  @dataset "backlinks_test"

  setup do
    Barkpark.Auth.create_token("backlinks-token", "dev", @dataset, ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [%{"name" => "author", "type" => "reference"}]
      },
      @dataset
    )

    {:ok, _} =
      Content.create_document("author", %{"_id" => "author-1", "title" => "Target"}, @dataset)

    {:ok, _} = Content.publish_document("author-1", "author", @dataset)

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "art-1", "title" => "Refs Target", "author" => "author-1"},
        @dataset
      )

    {:ok, _} = Content.publish_document("art-1", "article", @dataset)

    # reverse_referencers walks materialised content_edges (Phase 2); in tests we
    # materialise directly (publish alone doesn't), exactly as the graph/edges
    # suites do. from_id/to_id are doc_ids.
    Content.add_edges([%{from_id: "art-1", to_id: "author-1", kind: "references"}],
      dataset: @dataset
    )

    :ok
  end

  defp get_backlinks(conn, id, opts \\ []) do
    conn =
      if opts[:auth] == false,
        do: conn,
        else: put_req_header(conn, "authorization", "Bearer backlinks-token")

    get(conn, "/v1/data/backlinks/#{@dataset}/#{id}")
  end

  test "returns the documents that reference the target (authed)", %{conn: conn} do
    resp = get_backlinks(conn, "author-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    titles = Enum.map(body["result"]["backlinks"], & &1["title"])
    assert "Refs Target" in titles
    assert body["result"]["count"] >= 1
  end

  test "a doc with no referencers returns an empty backlinks list", %{conn: conn} do
    resp = get_backlinks(conn, "art-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["result"]["backlinks"] == []
    assert body["result"]["count"] == 0
  end

  test "without a token, backlinks 404s (existence-hiding)", %{conn: conn} do
    resp = get_backlinks(conn, "author-1", auth: false)
    assert resp.status == 404
  end
end
