defmodule BarkparkWeb.SharedEditTest do
  @moduledoc """
  P5 — the scoped-share EDIT write path, end-to-end over the real routes.

  SECURITY CONTRACT under test (each its own test):
    (1) a scope-bound edit token CAN mutate its OWN edit-shared scope;
    (2) the SAME token CANNOT mutate a different workspace/project;
    (3) ...nor a different DATASET of the same workspace (scope is byte-exact);
    (4) the token is REJECTED on the FLAT mutate route (the privilege-escalation
        hole the opaque-permission design closes — MUST stay closed);
    (4b/4c) the token is REJECTED on the FLAT READ routes too (GET /v1/data/doc
        + legacy GET /api/documents) — the wave-2 seal for the live-confirmed
        foreign-scope draft read (foreign-scope-share-token-flat-read);
    (5) an ANONYMOUS write to the shared scope is denied (no unauthenticated
        LAN writes — the owner's hard constraint);
    (6) downgrading the share :edit -> :read makes the token inert LIVE, before
        any revocation (the registry kill-switch);
    (7) a MEMBER is never locked out of their own edit-shared scope;
    (8) surface-exactness — a docs-only edit token is denied on the media route.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Media, Sharing}

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "shared-edit-admin"

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  @create %{
    "mutations" => [%{"create" => %{"_type" => "post", "_id" => "e1", "title" => "Edited"}}]
  }

  setup %{conn: conn} do
    ws_a = create_workspace!("edit-a")
    proj_a = create_project!(ws_a, "ep-a")
    ws_b = create_workspace!("edit-b")
    proj_b = create_project!(ws_b, "ep-b")

    for {ws, proj} <- [{ws_a, proj_a}, {ws_b, proj_b}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )
    end

    # ws_a is edit-shared for docs + media; ws_b is not shared at all.
    share_a!("docs,media:edit", ws_a, proj_a)
    # arpss-w8: snapshots :shares AND :shares_env (Sharing.refresh/0 reads both).
    Barkpark.SharingFixtures.snapshot_shares!()

    {:ok, {edit_token, _}} =
      Auth.create_share_token(ws_a.slug, proj_a.slug, @dataset, ["docs", "media"])

    # An admin token that is a MEMBER of ws_a (write via membership).
    {:ok, _} =
      Auth.create_token(@admin, "edit-admin", @dataset, ["read", "write", "admin"], ws_a.id)

    %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      edit_token: edit_token
    }
  end

  # arpss-w8: planted as a STORED row (Barkpark.SharingFixtures) so Sharing.refresh/0
  # rebuilds it instead of erasing it; snapshots :shares_env as well as :shares.
  defp share_a!(spec, ws, proj),
    do: Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:#{spec}")

  defp auth(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate_path(ws, proj, dataset \\ @dataset),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/mutate/#{dataset}"

  # Bearer header WITHOUT a json content-type, so a multipart upload encodes.
  defp bearer_only(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp media_upload_path(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@dataset}/upload"

  defp png_upload do
    tmp = Path.join(System.tmp_dir!(), "share-edit-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}
  end

  defp cleanup_upload(%{"result" => %{"id" => id, "url" => "/media/files/" <> rel}}) do
    File.rm(Path.join(Media.upload_dir(), rel))
    Barkpark.Media.Renditions.delete_for_file(id)
  end

  defp cleanup_upload(_), do: :ok

  # ── (1) the token writes its own scope ────────────────────────────────────

  test "a scope-bound edit token mutates its own edit-shared scope", ctx do
    resp = ctx.conn |> auth(ctx.edit_token) |> post(mutate_path(ctx.ws_a, ctx.proj_a), @create)
    assert resp.status == 200

    # the write landed in ws_a's scope
    drafts =
      Content.list_documents("post", @dataset,
        perspective: :drafts,
        workspace_id: ctx.ws_a.id,
        project_id: ctx.proj_a.id
      )

    assert Enum.any?(drafts, &(&1.title == "Edited"))
  end

  # ── (2)/(3) the token is bound to EXACTLY one scope ───────────────────────

  test "the token cannot mutate a different workspace/project", ctx do
    resp = ctx.conn |> auth(ctx.edit_token) |> post(mutate_path(ctx.ws_b, ctx.proj_b), @create)
    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  test "the token cannot mutate a different DATASET of its own workspace", ctx do
    resp =
      ctx.conn
      |> auth(ctx.edit_token)
      |> post(mutate_path(ctx.ws_a, ctx.proj_a, "staging"), @create)

    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  # ── (4) THE flat-route hole stays closed ──────────────────────────────────

  test "the token is REJECTED on the flat mutate route (no scope binding there)", ctx do
    resp = ctx.conn |> auth(ctx.edit_token) |> post("/v1/data/mutate/#{@dataset}", @create)
    assert resp.status in [401, 403]
    refute resp.status == 200

    # and nothing was written to the Default workspace via the flat route
    refute Enum.any?(
             Content.list_documents("post", @dataset, perspective: :drafts),
             &(&1.title == "Edited")
           )
  end

  # ── (4b/4c) the flat READ escape stays closed (wave-2 seal) ───────────────
  #
  # Live-confirmed on guerrilla (tooling/grip/ledger/foreign-share-token-flat-
  # read-live-confirm-2026-08-17.md): a foreign-scoped share-edit token — kind
  # "api", so authed — skipped the anonymous drafts clamp AND took
  # AssignDefaultScope's Default scope on the flat routes, reading a
  # Default-scoped draft 200/200 on BOTH GET /v1/data/doc/... and
  # GET /api/documents/... while anon got 404/401. Sealed at token resolution:
  # `RequireToken.share_token_off_surface?/2` (applied by BOTH RequireToken and
  # OptionalToken) refuses a `share_scope` token on any flat (non-
  # /w/:workspace_slug) route with 403. MUTATION PROOF: revert that predicate
  # (make it return false) → both reads below return 200 carrying the draft
  # body, redding these tests. Test (1) above is the positive control — the
  # token still writes its own scoped share routes with the seal in place.

  defp default_scoped_draft! do
    {ws, project} = ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

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

    id = "flat-read-#{System.unique_integer([:positive])}"

    # Draft-only: created, never published — its one row is `drafts.<id>`,
    # exactly the shape the live repro read across the scope boundary.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Default Draft", "content" => %{}},
        @dataset,
        scope
      )

    id
  end

  test "the token is REJECTED on the flat /v1/data/doc read (no scope binding there)", ctx do
    id = default_scoped_draft!()

    resp = ctx.conn |> auth(ctx.edit_token) |> get("/v1/data/doc/#{@dataset}/post/drafts.#{id}")

    assert resp.status in [401, 403]
    refute resp.resp_body =~ "Default Draft"
  end

  test "the token is REJECTED on the flat legacy /api/documents read", ctx do
    id = default_scoped_draft!()

    resp = ctx.conn |> auth(ctx.edit_token) |> get("/api/documents/post/drafts.#{id}")

    assert resp.status in [401, 403]
    refute resp.resp_body =~ "Default Draft"
  end

  # ── (5) no unauthenticated LAN writes ─────────────────────────────────────

  test "an anonymous write to the shared scope is denied", ctx do
    resp =
      ctx.conn
      |> put_req_header("content-type", "application/json")
      |> post(mutate_path(ctx.ws_a, ctx.proj_a), @create)

    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  # ── (6) the registry kill-switch ──────────────────────────────────────────

  test "downgrading the share to :read makes the token inert LIVE", ctx do
    share_a!("docs:read", ctx.ws_a, ctx.proj_a)

    resp = ctx.conn |> auth(ctx.edit_token) |> post(mutate_path(ctx.ws_a, ctx.proj_a), @create)
    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  # ── (7) members are never locked out ──────────────────────────────────────

  test "a member can still write their own edit-shared scope", ctx do
    resp = ctx.conn |> auth(@admin) |> post(mutate_path(ctx.ws_a, ctx.proj_a), @create)
    assert resp.status == 200
  end

  # ── (8) surface-exactness ────────────────────────────────────────────────

  test "a docs-only edit token is denied on the media write route", ctx do
    {:ok, {docs_only, _}} =
      Auth.create_share_token(ctx.ws_a.slug, ctx.proj_a.slug, @dataset, ["docs"])

    resp =
      ctx.conn
      |> auth(docs_only)
      |> post(media_upload_path(ctx.ws_a, ctx.proj_a), %{})

    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  # ── media edit ACTUALLY WORKS (the gap that hid the controller require_write
  #    bug) + its inverse surface-exactness ──────────────────────────────────

  test "a media edit token uploads a real asset to its scope", ctx do
    {:ok, {media_token, _}} =
      Auth.create_share_token(ctx.ws_a.slug, ctx.proj_a.slug, @dataset, ["media"])

    resp =
      ctx.conn
      |> bearer_only(media_token)
      |> post(media_upload_path(ctx.ws_a, ctx.proj_a), %{"file" => png_upload()})

    assert resp.status in [200, 201]
    body = json_response(resp, resp.status)
    on_exit(fn -> cleanup_upload(body) end)
  end

  test "a media-only edit token is denied on the docs mutate route (surface-exact inverse)",
       ctx do
    {:ok, {media_token, _}} =
      Auth.create_share_token(ctx.ws_a.slug, ctx.proj_a.slug, @dataset, ["media"])

    resp = ctx.conn |> auth(media_token) |> post(mutate_path(ctx.ws_a, ctx.proj_a), @create)
    assert resp.status in [401, 403, 404]
    refute resp.status == 200
  end

  # ── the browser path: a member with a SESSION cookie (no bearer) can still
  #    upload to a scoped project (the gap that hid the OptionalToken bug) ─────

  test "a member with a session cookie uploads media to a scoped project", ctx do
    resp =
      ctx.conn
      |> init_test_session(%{"api_token" => @admin})
      |> put_req_header("x-requested-with", "XMLHttpRequest")
      |> post(media_upload_path(ctx.ws_a, ctx.proj_a), %{"file" => png_upload()})

    assert resp.status in [200, 201]
    body = json_response(resp, resp.status)
    on_exit(fn -> cleanup_upload(body) end)
  end
end
