defmodule BarkparkWeb.GroqDocumentsTest do
  @moduledoc """
  task-6a540627a1aec2c1: Sanity's document read,
  `GET …/v{apiVersion}/data/doc/:dataset/:id[,id…]`, which `@sanity/client`'s
  `getDocument` / `getDocuments` call. Shapes are Sanity's, read from
  ecu57yeh/e2e-local on 2026-10-26: `{"documents": [...], "omitted":
  [{"id": "nope-xyz", "reason": "existence"}]}`, 200 even when nothing is found.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_docs_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-docs", name: "GROQ docs"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for id <- ["p1", "p2"] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id}, @dataset, scope)
      {:ok, _} = Content.publish_document(id, "post", @dataset, scope)
    end

    # A draft only: no published twin.
    {:ok, _} =
      Content.create_document("post", %{"_id" => "d1", "title" => "Draft"}, @dataset, scope)

    token = "groq-docs-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "docs", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  defp get_docs(conn, token, ids, query \\ "") do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> get("/w/groq-docs/p/site/v2025-02-19/data/doc/#{@dataset}/#{ids}#{query}")
    |> json_response(200)
  end

  test "one id answers the document, Sanity's shape", %{conn: conn, token: t} do
    assert %{
             "documents" => [%{"_id" => "p1", "_type" => "post", "title" => "p1"}],
             "omitted" => []
           } =
             get_docs(conn, t, "p1")
  end

  test "several ids answer in request order; a missing one is omitted, not an error", %{
    conn: conn,
    token: t
  } do
    body = get_docs(conn, t, "p2,nope-xyz,p1", "?tag=x")
    assert Enum.map(body["documents"], & &1["_id"]) == ["p2", "p1"]
    assert body["omitted"] == [%{"id" => "nope-xyz", "reason" => "existence"}]
  end

  test "a drafts. id names the draft, as a raw read by id does", %{conn: conn, token: t} do
    assert %{"documents" => [%{"_id" => "drafts.d1"}], "omitted" => []} =
             get_docs(conn, t, "drafts.d1")
  end

  # Auth is the query read's, unchanged: a `public-read` token is refused on
  # this path exactly as it is on /data/query (PublicRead's route allowlist).
  test "a public-read token gets the query read's answer: 403", %{conn: _conn} do
    pinned = "groq-docs-pub-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_workspace_by_slug("groq-docs")
    {:ok, _} = Auth.create_token(pinned, "docs-pub", @dataset, ["read", "public-read"], ws.id)

    for path <- [
          "/w/groq-docs/p/site/v2025-02-19/data/doc/#{@dataset}/p1",
          "/w/groq-docs/p/site/v2025-02-19/data/query/#{@dataset}?query=*"
        ] do
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> pinned)
      |> get(path)
      |> json_response(403)
    end
  end

  test "an unknown dataset is a 404, as for the query read", %{conn: conn, token: t} do
    conn
    |> put_req_header("authorization", "Bearer " <> t)
    |> get("/w/groq-docs/p/site/v2025-02-19/data/doc/no_such_ds/p1")
    |> json_response(404)
  end
end
