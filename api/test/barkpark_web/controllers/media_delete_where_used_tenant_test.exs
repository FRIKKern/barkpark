defmodule BarkparkWeb.MediaDeleteWhereUsedTenantTest do
  @moduledoc """
  task-00a41cec5455bc91 — the delete guard's where-used census ignored
  workspaces.

  `Media.WhereUsed.scan/1` ran `content::text LIKE '%/media/files/<path>%'`
  over EVERY published document on the instance. So `DELETE
  /v1/media/:dataset/:id` from workspace A answered its 409 with
  `referencedBy: [%{doc_id, type, dataset, title}]` naming ANOTHER
  workspace's documents (any tenant that hotlinked the public blob URL), and
  that tenant's reference counted toward `referencedByCount` and BLOCKED A's
  delete of its own blob.

  The census is still cross-DATASET on purpose (the blob keyspace is flat — see
  the `WhereUsed` moduledoc), but it is now confined to the blob's own
  workspace plus the shared NULL-workspace layer.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "where-used-tenant-admin"
  @dataset "production"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "where-used-tenant", "test", ["read", "write", "admin"])
    foreign = create_workspace!("wu-foreign-#{System.unique_integer([:positive])}")
    %{foreign: foreign, foreign_project: create_project!(foreign, "wu-foreign-p")}
  end

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin)

  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "wu-tenant-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    upload = %Plug.Upload{path: tmp, filename: "logo.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@dataset}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)
    Repo.get!(MediaFile, created["id"])
  end

  defp referencing_doc!(%MediaFile{} = file, workspace_id, project_id, title) do
    Repo.insert!(%Document{
      doc_id: "wu-tenant-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: @dataset,
      title: title,
      status: "published",
      workspace_id: workspace_id,
      project_id: project_id,
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{"blocks" => [%{"type" => "image", "src" => "/media/files/#{file.path}"}]}
    })
  end

  test "a FOREIGN workspace's reference neither blocks nor appears in the delete", ctx do
    file = media_file!()
    referencing_doc!(file, ctx.foreign.id, ctx.foreign_project.id, "Foreign tenant secret page")

    resp = admin(scoped_conn()) |> delete("/v1/media/#{@dataset}/#{file.id}")

    refute resp.resp_body =~ "Foreign tenant secret page"
    assert resp.status == 200, "a foreign hotlink blocked the owner's delete: #{resp.resp_body}"
    refute Repo.get(MediaFile, file.id)
  end

  test "CONTROL: the blob's OWN workspace still blocks and is named; the foreign one is not",
       ctx do
    file = media_file!()
    own = referencing_doc!(file, file.workspace_id, file.project_id, "Own page")
    foreign = referencing_doc!(file, ctx.foreign.id, ctx.foreign_project.id, "Foreign page")

    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@dataset}/#{file.id}")
      |> json_response(409)

    details = body["error"]["details"]
    assert details["referencedByCount"] == 1
    assert Enum.map(details["referencedBy"], & &1["doc_id"]) == [own.doc_id]
    refute Jason.encode!(body) =~ foreign.doc_id
    assert Repo.get(MediaFile, file.id)
  end
end
