defmodule BarkparkWeb.ShareLinkTest do
  @moduledoc """
  P7 — ITEM (per-document) share links: mint → `/s/:token` resolves the ONE
  bound item (paper / doc / media), scoped to the LINK's own workspace and
  INDEPENDENT of any section share. Revocable; admin-only management.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Media}
  alias Barkpark.Media.MediaFile
  alias Barkpark.Repo

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "share-link-admin"
  @junior "share-link-junior"

  setup %{conn: conn} do
    {:ok, _} = Auth.create_token(@admin, "sl-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior, "sl-junior", @dataset, ["read", "write"])

    ws = create_workspace!("link-ws")
    proj = create_project!(ws, "link-proj")
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

    # A published paper + a published post in this scope.
    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "demo-paper",
          "title" => "Demo Paper",
          "content" => %{"body_html" => "<h1>Shared via a direct link</h1>"}
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("demo-paper", "paper", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "post1", "title" => "A Post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("post1", "post", @dataset, scope)

    media = put_media!(ws, proj)

    # No section share active — proves item links are independent.
    Application.delete_env(:barkpark, :shares)

    %{
      conn: conn,
      ws: ws,
      proj: proj,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      media: media
    }
  end

  defp put_media!(ws, proj) do
    name = "link-#{System.unique_integer([:positive])}.png"
    rel = "uploads/share-link-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "PNG-BYTES")
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: 9,
      dataset: @dataset,
      workspace_id: ws.id,
      project_id: proj.id
    })
    |> Repo.insert!()
  end

  defp admin(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@admin}")
      |> put_req_header("content-type", "application/json")

  defp junior(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@junior}")
      |> put_req_header("content-type", "application/json")

  defp mint(conn, body),
    do: conn |> admin() |> post("/v1/shares/links", body) |> json_response(201)

  # ── paper link ────────────────────────────────────────────────────────────

  test "a PAPER link renders the paper at /s/:token (no section share)", %{
    conn: conn,
    scope_str: scope
  } do
    %{"token" => token, "url" => url} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "paper", ref_id: "demo-paper"})

    assert url == "/s/#{token}"
    resp = get(build_conn(), "/s/#{token}")
    assert resp.status == 200
    assert resp.resp_body =~ "Shared via a direct link"
  end

  # ── doc link ──────────────────────────────────────────────────────────────

  test "a DOC link returns the document JSON at /s/:token", %{conn: conn, scope_str: scope} do
    %{"token" => token} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    body = get(build_conn(), "/s/#{token}") |> json_response(200)
    assert body["_id"] == "post1"
    assert body["title"] == "A Post"
  end

  # ── media link ──────────────────────────────────────────────────────────

  test "a MEDIA link serves the file bytes at /s/:token", %{
    conn: conn,
    scope_str: scope,
    media: media
  } do
    %{"token" => token} = mint(conn, %{scope: scope, kind: "media", ref_id: media.id})

    resp = get(build_conn(), "/s/#{token}")
    assert resp.status == 200
    assert resp.resp_body == "PNG-BYTES"
  end

  # ── revoke + invalid ──────────────────────────────────────────────────────

  test "revoking a link makes /s/:token 404", %{conn: conn, scope_str: scope} do
    %{"token" => token, "link" => link} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    assert get(build_conn(), "/s/#{token}").status == 200

    assert conn
           |> admin()
           |> delete("/v1/shares/links/#{link["id"]}")
           |> json_response(200)
           |> Map.get("revoked") == true

    assert get(build_conn(), "/s/#{token}").status == 404
  end

  test "a garbage token is 404", %{} do
    assert get(build_conn(), "/s/not-a-real-token").status == 404
  end

  # ── admin gating + validation ─────────────────────────────────────────────

  test "minting / listing / revoking are admin-only", %{conn: conn, scope_str: scope} do
    body = %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"}
    assert conn |> post("/v1/shares/links", body) |> Map.get(:status) == 401
    assert conn |> junior() |> post("/v1/shares/links", body) |> Map.get(:status) == 403

    assert conn
           |> junior()
           |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")
           |> Map.get(:status) == 403

    assert conn |> junior() |> delete("/v1/shares/links/x") |> Map.get(:status) == 403
  end

  test "minting a link for a non-existent item is 422", %{conn: conn, scope_str: scope} do
    resp =
      conn
      |> admin()
      |> post("/v1/shares/links", %{scope: scope, kind: "doc", ref_type: "post", ref_id: "ghost"})

    assert resp.status == 422
  end

  test "list shows an item's links (no token/hash)", %{conn: conn, scope_str: scope} do
    mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    list =
      conn
      |> admin()
      |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")
      |> json_response(200)

    assert length(list["links"]) == 1
    refute Map.has_key?(hd(list["links"]), "token_hash")
    refute Map.has_key?(hd(list["links"]), "token")
  end
end
