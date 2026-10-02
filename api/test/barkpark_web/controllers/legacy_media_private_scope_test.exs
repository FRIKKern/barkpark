defmodule BarkparkWeb.LegacyMediaPrivateScopeTest do
  @moduledoc """
  task-9da62af15358cd62: the LEGACY media routes (`GET /media/:id/meta`,
  `/media/files/*path`, `/media/renditions/:id/:preset` and the `/w/:ws/p/:proj`
  mirror) gate on `Access.allowed?(conn, file, doc, …)`, but looked the asset
  doc up with `Media.asset_doc_for_file(file, file.dataset)` and NO scope. The
  unscoped lookup resolves the dataset inside the Default project, so for a file
  in any other workspace it returned nil, and `Access.visibility(nil)` is
  "public": a PRIVATE asset was served to a caller who may only see public ones.
  V1 fixed the same bug (`asset_doc/2`); the legacy controller never got it.

  The caller here is a `public-read` token of the asset's own workspace — the
  site credential that ships in public builds — on the flat route, where the
  workspace comes from the token. An ADMIN CONTROL on the same doors proves the
  fixture is visible, so a refusal is not an empty-fixture false green.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Media, Repo, Tenancy}
  alias Barkpark.Media.Storage.MediaFile

  @ds "production"

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @ds, perms, ws_id)
    raw
  end

  defp get_as(conn, raw, path),
    do: conn |> put_req_header("authorization", "Bearer " <> raw) |> get(path)

  setup do
    uniq = System.unique_integer([:positive])
    ws = create_workspace!("lmps-ws-#{uniq}")
    proj = create_project!(ws, "lmps-proj-#{uniq}")
    scope = [workspace_id: ws.id, project_id: proj.id]
    {:ok, dataset} = Tenancy.get_or_create_dataset(proj, @ds)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "mediaAsset",
          "title" => "Media Asset",
          "visibility" => "private",
          "fields" => []
        },
        @ds,
        scope
      )

    file = put_file!(uniq, ws, proj, dataset)

    doc_id = "lmps-asset-#{uniq}"

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "_id" => doc_id,
          "title" => "Confidential",
          "mediaFileId" => file.id,
          "bp_visibility" => "private"
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "mediaAsset", @ds, scope)

    %{
      asset_file: file,
      admin: mint!("lmps-admin", ["read", "write", "admin"], ws.id),
      public_read: mint!("lmps-pr", ["public-read"], ws.id)
    }
  end

  defp put_file!(uniq, ws, proj, dataset) do
    name = "lmps-#{uniq}.png"
    rel = "uploads/legacy-media-private-scope-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "PRIVATE-BYTES")
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: 13,
      dataset: @ds,
      dataset_id: dataset.id,
      workspace_id: ws.id,
      project_id: proj.id
    })
    |> Repo.insert!()
  end

  test "a public-read caller is refused the private asset's metadata", ctx do
    resp = get_as(scoped_conn(), ctx.public_read, "/media/#{ctx.asset_file.id}/meta")

    refute resp.status == 200,
           "a PRIVATE asset outside Default was answered as public (status #{resp.status})"
  end

  test "a public-read caller is refused the private asset's bytes", ctx do
    resp = get_as(scoped_conn(), ctx.public_read, "/media/files/#{ctx.asset_file.path}")

    refute resp.status == 200
    refute resp.resp_body == "PRIVATE-BYTES"
  end

  test "CONTROL: an admin of the workspace still gets the metadata and the bytes", ctx do
    assert get_as(scoped_conn(), ctx.admin, "/media/#{ctx.asset_file.id}/meta").status == 200

    served = get_as(scoped_conn(), ctx.admin, "/media/files/#{ctx.asset_file.path}")
    assert served.status == 200
    assert served.resp_body == "PRIVATE-BYTES"
  end
end
