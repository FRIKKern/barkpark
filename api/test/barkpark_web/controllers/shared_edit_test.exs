defmodule BarkparkWeb.SharedEditTest do
  @moduledoc """
  P5 — the scoped-share EDIT write path, end-to-end over the real routes.

  SECURITY CONTRACT under test (each its own test):
    (1) a scope-bound edit token CAN mutate its OWN edit-shared scope;
    (2) the SAME token CANNOT mutate a different workspace/project;
    (3) ...nor a different DATASET of the same workspace (scope is byte-exact);
    (4) the token is REJECTED on the FLAT mutate route (the privilege-escalation
        hole the opaque-permission design closes — MUST stay closed);
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
    prior = Application.get_env(:barkpark, :shares)
    share_a!("docs,media:edit", ws_a, proj_a)
    on_exit(fn -> restore(prior) end)

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

  defp restore(nil), do: Application.delete_env(:barkpark, :shares)
  defp restore(v), do: Application.put_env(:barkpark, :shares, v)

  defp share_a!(spec, ws, proj),
    do:
      Application.put_env(
        :barkpark,
        :shares,
        Sharing.parse("#{ws.slug}/#{proj.slug}/#{@dataset}:#{spec}")
      )

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
