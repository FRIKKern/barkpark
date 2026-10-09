defmodule BarkparkWeb.Integration.MediaDeleteTenantScopeGapTest do
  @moduledoc """
  P1 live bug, task-4bffdfa43b24e4a5 — found by barkpark-studio on guerrilla
  (7ac8073c1, #22427's own merge) in a REAL tenant workspace (`studio-parity`,
  dataset `e2e-freeform`): the structural delete guard
  (`Barkpark.Media.WhereUsed.structural_referrers/1`, task-5f6e7ae324334044)
  silently finds ZERO hits for a document that lives in a non-default
  workspace, so an unforced DELETE answers 200 even while a live document's
  image/file field still references the blob via `{asset: {_ref}}`.

  ROOT CAUSE: `structural_referrers/1` passed `MediaFile.scope_opts(file)`
  (workspace_id/project_id) into `Media.asset_doc_for_file/3` but NOT into the
  following `Content.Query.list_reference_holders/3` call — only
  `caller_context`. `list_reference_holders/3`'s `base_query/4` calls
  `scope_to_workspace_or_global(query, nil, nil)`, which with BOTH args nil
  falls to `scope_to_workspace_global/1` — rows with `workspace_id IS NULL`
  ONLY. A document stamped with a REAL workspace_id is therefore completely
  invisible to the structural lookup: it finds 0 rows and the delete proceeds.

  This file reproduces it through the REAL scoped upload endpoint
  (`POST /w/:ws/p/:proj/v1/media/:dataset/upload`) in a freshly created,
  non-default workspace — mirroring the exact tenancy shape of the live
  report, which a default-workspace fixture (what task-5f6e7ae324334044's own
  tests used) cannot catch.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @ds "e2e-freeform"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup %{conn: conn} do
    ws = create_workspace!("mtsg-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "mtsg-p-#{System.unique_integer([:positive])}")

    raw = "mtsg-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "media tenant scope gap", @ds, ["read", "write"])
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "mtsg_post",
          "title" => "MTSG Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "mainImage", "type" => "image"},
            %{"name" => "attachment", "type" => "file"}
          ]
        },
        @ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    %{conn: conn, ws: ws, proj: proj}
  end

  defp png_upload do
    path = Path.join(System.tmp_dir!(), "mtsg-#{System.unique_integer([:positive])}.png")
    File.write!(path, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "cast.png", content_type: "image/png"}
  end

  # THE REAL HTTP UPLOAD DOOR, scoped — exactly the barkpark-studio repro's
  # step 1, not a fixture-built MediaFile/mediaAsset pair.
  defp upload!(conn, ws, proj) do
    conn
    |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/upload", %{"file" => png_upload()})
    |> json_response(201)
    |> Map.fetch!("result")
  end

  defp mutate!(conn, ws, proj, mutation) do
    conn
    |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/data/mutate/#{@ds}", %{"mutations" => [mutation]})
    |> json_response(200)
  end

  describe "DELETE /w/:ws/p/:proj/v1/media/:dataset/:id — a document in a REAL (non-default) workspace" do
    test "refuses 409 when a draft in this workspace references the blob via an image field's {asset: {_ref}}",
         %{conn: conn, ws: ws, proj: proj} do
      uploaded = upload!(conn, ws, proj)
      # The upload receipt's assetDocId is DRAFT-prefixed (the companion
      # mediaAsset document is created as a draft); the field's own _ref is
      # the bare, published-normalized form — the exact shape barkpark-studio's
      # repro used.
      asset_doc_id = Content.published_id(uploaded["assetDocId"])

      mutate!(conn, ws, proj, %{
        "create" => %{
          "_id" => "mtsg-post-1",
          "_type" => "mtsg_post",
          "title" => "Tenant-scoped post",
          "mainImage" => %{"asset" => %{"_ref" => asset_doc_id}}
        }
      })

      resp =
        conn
        |> delete("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{uploaded["id"]}")

      assert resp.status == 409,
             "THE BUG: the blob was deleted (status #{resp.status}) despite a live " <>
               "document in this workspace referencing it — the structural guard never " <>
               "received this workspace's scope"

      assert Repo.get(MediaFile, uploaded["id"]),
             "the guard answered 409 but the blob row was deleted anyway"
    end

    test "refuses 409 when a PUBLISHED document in this workspace references the blob via a file field",
         %{conn: conn, ws: ws, proj: proj} do
      uploaded = upload!(conn, ws, proj)
      asset_doc_id = Content.published_id(uploaded["assetDocId"])

      mutate!(conn, ws, proj, %{
        "create" => %{
          "_id" => "mtsg-post-2",
          "_type" => "mtsg_post",
          "title" => "Tenant-scoped post 2",
          "attachment" => %{"asset" => %{"_ref" => asset_doc_id}}
        }
      })

      mutate!(conn, ws, proj, %{"publish" => %{"id" => "mtsg-post-2", "type" => "mtsg_post"}})

      resp = conn |> delete("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{uploaded["id"]}")

      assert resp.status == 409
      assert Repo.get(MediaFile, uploaded["id"])
    end

    test "?force=true still deletes a referenced blob in a real workspace", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      uploaded = upload!(conn, ws, proj)
      asset_doc_id = Content.published_id(uploaded["assetDocId"])

      mutate!(conn, ws, proj, %{
        "create" => %{
          "_id" => "mtsg-post-3",
          "_type" => "mtsg_post",
          "title" => "Forced",
          "mainImage" => %{"asset" => %{"_ref" => asset_doc_id}}
        }
      })

      resp =
        conn
        |> delete("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{uploaded["id"]}?force=true")

      assert resp.status in [200, 201]
      refute Repo.get(MediaFile, uploaded["id"])
    end

    test "an UNREFERENCED blob in a real workspace still deletes", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      uploaded = upload!(conn, ws, proj)

      resp = conn |> delete("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{uploaded["id"]}")

      assert resp.status in [200, 201]
      refute Repo.get(MediaFile, uploaded["id"])
    end
  end
end
