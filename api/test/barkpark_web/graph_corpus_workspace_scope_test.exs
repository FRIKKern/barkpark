defmodule BarkparkWeb.GraphCorpusWorkspaceScopeTest do
  @moduledoc """
  stw-backlog-graph-ws-scope — the flat `GET /v1/graph` corpus must resolve the
  workspace from the bearer token, the same authority content search uses.

  Filed 2026-07-16 when the flat graph read `AssignDefaultScope`'s seeded
  Default workspace for every caller (a spawned site whose content lived in a
  non-default workspace got an EMPTY graph while search worked). #13886
  (8dd6600f9, 2026-08-24) put `DeriveWorkspaceFromToken` ahead of the Default
  fallback on the `:api` pipeline `/v1/graph` rides, but nothing pinned the
  graph surface itself. This does, reading the NODES returned — a 200 from the
  wrong workspace is the defect, so a status assertion is vacuous.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @type_name "graph-ws-post"

  setup do
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    default_scope = [workspace_id: default_ws.id, project_id: default_project.id]

    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)
    scope_b = [workspace_id: ws_b.id, project_id: project_b.id]

    for scope <- [default_scope, scope_b] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => @type_name,
            "title" => @type_name,
            "fields" => [%{"name" => "title", "type" => "string"}],
            "visibility" => "public"
          },
          @dataset,
          scope
        )
    end

    publish!("graph-default-1", default_scope)
    publish!("graph-b-1", scope_b)

    # A draft-only doc in B: the corpus graph is the PUBLISHED lens.
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "drafts.graph-b-draft", "title" => "draft only"},
        @dataset,
        scope_b
      )

    {:ok, _} = Auth.create_token("graph-ws-b", "graph-ws-b", @dataset, ["read"], ws_b.id)

    {:ok, _} =
      Auth.create_token("graph-ws-default", "graph-ws-default", @dataset, ["read"], default_ws.id)

    :ok
  end

  defp publish!(id, scope) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "drafts." <> id, "title" => id},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, @type_name, @dataset, scope)
  end

  defp node_ids(conn, token) do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/graph?dataset=#{@dataset}&types=#{@type_name}")
      |> json_response(200)

    body["nodes"] |> Enum.map(& &1["id"]) |> MapSet.new()
  end

  test "a workspace-B token's flat graph carries B's published nodes and none of Default's",
       %{conn: conn} do
    ids = node_ids(conn, "graph-ws-b")
    assert "graph-b-1" in ids
    refute "graph-default-1" in ids
    refute Enum.any?(ids, &String.contains?(&1, "graph-b-draft"))
  end

  test "a Default-workspace token's flat graph carries Default's nodes and none of B's",
       %{conn: conn} do
    ids = node_ids(conn, "graph-ws-default")
    assert "graph-default-1" in ids
    refute "graph-b-1" in ids
  end
end
