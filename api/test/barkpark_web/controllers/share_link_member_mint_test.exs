defmodule BarkparkWeb.ShareLinkMemberMintTest do
  @moduledoc """
  task-d50757dc446514e7 — `POST /v1/shares/links` widened from admin-only to
  any write-capable workspace MEMBER (barkpark-studio's gap: Sanity lets an
  editor mint a share link, the same posture task-ea6c9abb868593f8 shipped
  for preview tokens). `GET`/`DELETE` stay admin-only, untouched — covered by
  the existing `share_link_test.exs` tenancy-confinement describe block.

  Covers the THREE things this widening had to get right without opening a
  new hole:

    * a write-capable member mints `access: "read"` (the default) for their
      OWN workspace — the base case barkpark-studio asked for.
    * a read-only member (no "write" in the token's own flat permissions)
      still cannot mint at all — the gate is `:require_write`-shaped, not
      bare membership.
    * `access: "edit"` stays admin-gated even for a write-capable member — it
      hands the link's holder EDIT authority on the item, a bigger grant
      than the read-only default, mirroring `multi_use` staying admin-only
      on the preview-token mint.

  Also pins the `dataset_bound` (#22393) fix: confirmed LIVE, before writing
  it, that a dataset_bound token bypassed this route's confinement entirely
  (the dataset rides inside the composite `scope` string, which neither
  `RequireToken` nor `OptionalToken`'s `dataset_off_binding?/2` parses) — a
  pre-existing gap, not introduced by this widening, but one that becomes
  materially exploitable once a member (more likely than an admin to be
  dataset_bound) can reach mint at all.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws = Barkpark.TenancyFixtures.create_workspace!("slmm-ws-#{suffix}")
    proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} = Content.create_document("post", %{"doc_id" => "slmm-post", "title" => "T"}, @dataset, scope)
    {:ok, _} = Content.publish_document("slmm-post", "post", @dataset, scope)

    admin_raw = "slmm-admin-#{suffix}"
    {:ok, admin_tok} = Auth.create_token(admin_raw, "slmm-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    writer_raw = "slmm-writer-#{suffix}"
    {:ok, writer_tok} = Auth.create_token(writer_raw, "slmm-writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, writer_tok.id, "member")

    reader_raw = "slmm-reader-#{suffix}"
    {:ok, reader_tok} = Auth.create_token(reader_raw, "slmm-reader", @dataset, ["read"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, reader_tok.id, "member")

    bound_raw = "slmm-bound-#{suffix}"

    {:ok, bound_tok} =
      Auth.create_token(bound_raw, "slmm-bound", "staging", ["read", "write"], nil,
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
    Map.merge(%{"scope" => scope, "kind" => "doc", "ref_type" => "post", "ref_id" => "slmm-post"}, overrides)
  end

  test "a write-capable member mints a read-access link for their own workspace", %{
    conn: conn,
    scope_str: scope,
    writer_raw: raw
  } do
    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(scope)) |> json_response(201)

    assert resp["link"]["access"] == "read"
    assert resp["link"]["ref_id"] == "slmm-post"
    assert String.starts_with?(resp["url"], "http")
  end

  test "a read-only member (no write permission) still cannot mint", %{
    conn: conn,
    scope_str: scope,
    reader_raw: raw
  } do
    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(scope))
    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
  end

  test "a write-capable member's access: edit request is refused -- admin-only knob", %{
    conn: conn,
    scope_str: scope,
    writer_raw: raw
  } do
    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(scope, %{"access" => "edit"}))
    assert resp.status == 403

    assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden",
           "a non-admin member must not manufacture an edit credential: #{resp.resp_body}"
  end

  test "an admin's access: edit request still works -- the knob is admin-only, not removed", %{
    conn: conn,
    scope_str: scope,
    admin_raw: raw
  } do
    resp =
      conn |> bearer(raw) |> post("/v1/shares/links", mint_body(scope, %{"access" => "edit"})) |> json_response(201)

    assert resp["link"]["access"] == "edit"
  end

  test "a totally anonymous caller cannot mint", %{conn: conn, scope_str: scope} do
    resp = conn |> put_req_header("content-type", "application/json") |> post("/v1/shares/links", mint_body(scope))
    assert resp.status in [401, 403]
  end

  # ── dataset_bound (#22393) ───────────────────────────────────────────────

  test "a dataset_bound member cannot mint a link scoped to a DIFFERENT dataset than their own token is bound to",
       %{conn: conn, ws: ws, bound_raw: raw} do
    other_scope = "#{ws.slug}/default/#{@dataset}"

    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(other_scope))

    assert resp.status == 403

    assert Jason.decode!(resp.resp_body)["error"]["reason"] == "dataset_not_bound",
           "expected the dataset-binding refusal, got: #{resp.resp_body}"
  end

  test "a dataset_bound member CAN mint a link for their own bound dataset", %{conn: conn, ws: ws, bound_raw: raw} do
    proj = Tenancy.get_project(ws.slug, "default")

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "slmm-staging-post", "title" => "T"}, "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.publish_document("slmm-staging-post", "post", "staging",
        workspace_id: ws.id,
        project_id: proj.id
      )

    resp =
      conn
      |> bearer(raw)
      |> post(
        "/v1/shares/links",
        mint_body("#{ws.slug}/default/staging", %{"ref_id" => "slmm-staging-post"})
      )
      |> json_response(201)

    assert resp["link"]["dataset"] == "staging"
  end

  # ── nonexistent ref answers the SAME as forbidden/not-found, never a leak ─

  test "a nonexistent ref_id is a 422, never a 500 or a 201", %{
    conn: conn,
    scope_str: scope,
    writer_raw: raw
  } do
    resp = conn |> bearer(raw) |> post("/v1/shares/links", mint_body(scope, %{"ref_id" => "does-not-exist"}))
    assert resp.status == 422
  end
end
