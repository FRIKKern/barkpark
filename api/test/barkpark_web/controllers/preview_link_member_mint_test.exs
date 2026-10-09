defmodule BarkparkWeb.PreviewLinkMemberMintTest do
  @moduledoc """
  task-9cfe08fe1e91b6c9 — `POST /v1/shares/preview-links` widened from
  admin-only to any write-capable workspace MEMBER, the third and final
  sibling of this widening series (after task-ea6c9abb868593f8's preview
  tokens and task-d50757dc446514e7's share links). `GET`/`DELETE` stay
  admin-only, untouched — covered by the existing `preview_link_test.exs`.

  Covers the two things this widening had to get right:

    * a write-capable member mints a preview link (draft or published doc)
      for their OWN workspace -- the base case.
    * a read-only member (no "write" in the token's own flat permissions)
      still cannot mint at all -- the gate is `:require_write`-shaped, not
      bare membership.

  Unlike its two siblings there is no access-level or single/multi-use knob
  on this controller at all (`preview_links` carries no such field), so
  there is nothing separate to keep admin-gated once `mint` itself widens.

  Also pins the `dataset_bound` (#22393) fix, applied here PRE-EMPTIVELY
  (task-d50757dc446514e7 found this exact gap live on the sibling
  `ShareLinkController.mint/2`): the dataset rides inside the composite
  `scope` string, which neither `RequireToken` nor `OptionalToken`'s
  `dataset_off_binding?/2` parses.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws = Barkpark.TenancyFixtures.create_workspace!("plmm-ws-#{suffix}")
    proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # DRAFT, never published -- this feature's entire point.
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "plmm-post", "title" => "T"}, @dataset, scope)

    admin_raw = "plmm-admin-#{suffix}"

    {:ok, admin_tok} =
      Auth.create_token(admin_raw, "plmm-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    writer_raw = "plmm-writer-#{suffix}"
    {:ok, writer_tok} = Auth.create_token(writer_raw, "plmm-writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, writer_tok.id, "member")

    reader_raw = "plmm-reader-#{suffix}"
    {:ok, reader_tok} = Auth.create_token(reader_raw, "plmm-reader", @dataset, ["read"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, reader_tok.id, "member")

    bound_raw = "plmm-bound-#{suffix}"

    {:ok, bound_tok} =
      Auth.create_token(bound_raw, "plmm-bound", "staging", ["read", "write"], nil,
        dataset_bound: true
      )

    {:ok, _} = TenancyAuth.create_membership(ws.id, bound_tok.id, "member")

    %{
      conn: conn,
      ws: ws,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      admin_raw: admin_raw,
      writer_raw: writer_raw,
      reader_raw: reader_raw,
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
      %{"scope" => scope, "ref_type" => "post", "doc_id" => "drafts.plmm-post"},
      overrides
    )
  end

  test "a write-capable member mints a preview link for a DRAFT in their own workspace", %{
    conn: conn,
    scope_str: scope,
    writer_raw: raw
  } do
    resp =
      conn
      |> bearer(raw)
      |> post("/v1/shares/preview-links", mint_body(scope))
      |> json_response(201)

    assert resp["link"]["doc_id"] == "drafts.plmm-post"
    assert String.ends_with?(resp["url"], "/sp/" <> resp["token"])
  end

  test "a read-only member (no write permission) still cannot mint", %{
    conn: conn,
    scope_str: scope,
    reader_raw: raw
  } do
    resp = conn |> bearer(raw) |> post("/v1/shares/preview-links", mint_body(scope))
    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
  end

  test "a totally anonymous caller cannot mint", %{conn: conn, scope_str: scope} do
    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/v1/shares/preview-links", mint_body(scope))

    assert resp.status in [401, 403]
  end

  test "an admin can still mint, unaffected by the member widening", %{
    conn: conn,
    scope_str: scope,
    admin_raw: raw
  } do
    resp =
      conn
      |> bearer(raw)
      |> post("/v1/shares/preview-links", mint_body(scope))
      |> json_response(201)

    assert resp["link"]["doc_id"] == "drafts.plmm-post"
  end

  # ── dataset_bound (#22393) ───────────────────────────────────────────────

  test "a dataset_bound member cannot mint a link scoped to a DIFFERENT dataset than their own token is bound to",
       %{conn: conn, ws: ws, bound_raw: raw} do
    other_scope = "#{ws.slug}/default/#{@dataset}"

    resp = conn |> bearer(raw) |> post("/v1/shares/preview-links", mint_body(other_scope))

    assert resp.status == 403

    assert Jason.decode!(resp.resp_body)["error"]["reason"] == "dataset_not_bound",
           "expected the dataset-binding refusal, got: #{resp.resp_body}"
  end

  test "a dataset_bound member CAN mint a link for their own bound dataset", %{
    conn: conn,
    ws: ws,
    bound_raw: raw
  } do
    proj = Tenancy.get_project(ws.slug, "default")

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
        %{"doc_id" => "plmm-staging-post", "title" => "T"},
        "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    resp =
      conn
      |> bearer(raw)
      |> post(
        "/v1/shares/preview-links",
        mint_body("#{ws.slug}/default/staging", %{"doc_id" => "drafts.plmm-staging-post"})
      )
      |> json_response(201)

    assert resp["link"]["dataset"] == "staging"
  end

  # ── nonexistent doc answers the SAME as forbidden/not-found, never a leak ─

  test "a nonexistent doc_id is a 422, never a 500 or a 201", %{
    conn: conn,
    scope_str: scope,
    writer_raw: raw
  } do
    resp =
      conn
      |> bearer(raw)
      |> post(
        "/v1/shares/preview-links",
        mint_body(scope, %{"doc_id" => "drafts.does-not-exist"})
      )

    assert resp.status == 422
  end
end
