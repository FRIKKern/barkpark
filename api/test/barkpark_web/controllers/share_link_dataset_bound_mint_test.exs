defmodule BarkparkWeb.ShareLinkDatasetBoundMintTest do
  @moduledoc """
  task-03be4306d4226582 — `POST /v1/shares/links` reads its dataset from the
  composite `scope` param (`"ws/project/dataset"`), which
  `dataset_off_binding?/2` (task-4418b517649a58ce, #22393) never parses: that
  function reads the requested dataset from a literal top-level `dataset`
  param or path segment only. So a `dataset_bound` token — admin included —
  could mint a share link scoped to ANY other dataset in its workspace,
  bypassing the binding entirely. Confirmed live before writing the fix: a
  token bound to "staging" minted a link scoped to "production" with a 201.

  Extracted from run8-sweep/member-share-link-mint (#22484, still closed
  pending an owner ruling on its separate member-widening change) at
  team-lead's request — this fix is independent of that pending work. Mint
  stays admin-only here; `ensure_workspace_admin/2` is untouched.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws = Barkpark.TenancyFixtures.create_workspace!("slmdb-ws-#{suffix}")
    proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "slmdb-post", "title" => "T"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("slmdb-post", "post", @dataset, scope)

    bound_raw = "slmdb-bound-admin-#{suffix}"

    {:ok, bound_tok} =
      Auth.create_token(
        bound_raw,
        "slmdb-bound-admin",
        "staging",
        ["read", "write", "admin"],
        nil,
        dataset_bound: true
      )

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, bound_tok.id, "admin")

    %{
      conn: conn,
      ws: ws,
      proj: proj,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      bound_raw: bound_raw
    }
  end

  defp bearer(conn, raw),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

  defp mint_body(scope, overrides \\ %{}) do
    Map.merge(
      %{"scope" => scope, "kind" => "doc", "ref_type" => "post", "ref_id" => "slmdb-post"},
      overrides
    )
  end

  test "a staging-bound admin token minting a PRODUCTION-scoped link gets 403 dataset_not_bound",
       %{conn: conn, scope_str: production_scope, bound_raw: raw} do
    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(production_scope))

    assert resp.status == 403

    assert Jason.decode!(resp.resp_body)["error"]["reason"] == "dataset_not_bound",
           "expected the dataset-binding refusal, got: #{resp.resp_body}"
  end

  test "the same staging-bound admin token CAN still mint a link for its own bound dataset", %{
    conn: conn,
    ws: ws,
    proj: proj,
    bound_raw: raw
  } do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "slmdb-staging-post", "title" => "T"},
        "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.publish_document("slmdb-staging-post", "post", "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    resp =
      conn
      |> bearer(raw)
      |> post(
        "/v1/shares/links",
        mint_body("#{ws.slug}/#{proj.slug}/staging", %{"ref_id" => "slmdb-staging-post"})
      )
      |> json_response(201)

    assert resp["link"]["dataset"] == "staging"
  end

  test "an UNBOUND admin token still mints across datasets in its workspace, unchanged", %{
    conn: conn,
    ws: ws,
    scope_str: production_scope
  } do
    suffix = System.unique_integer([:positive])
    unbound_raw = "slmdb-unbound-admin-#{suffix}"

    {:ok, unbound_tok} =
      Auth.create_token(unbound_raw, "slmdb-unbound-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, unbound_tok.id, "admin")

    resp =
      conn
      |> bearer(unbound_raw)
      |> post("/v1/shares/links", mint_body(production_scope))
      |> json_response(201)

    assert resp["link"]["dataset"] == @dataset
  end

  test "a totally anonymous caller still cannot mint (dataset_bound does not weaken this)", %{
    conn: conn,
    scope_str: production_scope
  } do
    resp = conn |> post("/v1/shares/links", mint_body(production_scope))
    assert resp.status in [401, 403]
  end
end
