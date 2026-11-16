defmodule BarkparkWeb.MediaDeleteRefusalVisibleTest do
  @moduledoc """
  task-29ef6d1ab344a01b — a refused media delete named documents the caller
  cannot read.

  The delete guard's census counts every document in the file's workspace that
  uses it, in every project and for every owner, because the delete must refuse
  on any of them. The 409 handed that census's `referencedBy` sample (doc ids
  and titles) back to the caller as is, so a writer in one project read the
  titles of another project's documents. The refusal now names only documents
  the caller can read by id; the count, and so the refusal, stay the gate's.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "refusal-visible-admin"
  @dataset "production"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "refusal-visible", "test", ["read", "write", "admin"])
    {ws, _proj} = ensure_default_scope!()

    %{
      ws: ws,
      sibling: create_project!(ws, "refusal-sibling-#{System.unique_integer([:positive])}")
    }
  end

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin)

  defp media_file! do
    tmp =
      Path.join(System.tmp_dir!(), "refusal-visible-#{System.unique_integer([:positive])}.png")

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

  defp using_doc!(%MediaFile{} = file, project_id, title) do
    Repo.insert!(%Document{
      doc_id: "refusal-visible-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: @dataset,
      title: title,
      status: "published",
      workspace_id: file.workspace_id,
      project_id: project_id,
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{"blocks" => [%{"type" => "image", "src" => "/media/files/#{file.path}"}]}
    })
  end

  test "the refusal names the caller's own document and never one from another project", ctx do
    file = media_file!()
    assert file.workspace_id == ctx.ws.id
    own = using_doc!(file, file.project_id, "Own launch page")
    hidden = using_doc!(file, ctx.sibling.id, "Sibling project secret plan")

    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@dataset}/#{file.id}")
      |> json_response(409)

    details = body["error"]["details"]
    assert Enum.map(details["referencedBy"], & &1["doc_id"]) == [own.doc_id]
    assert details["referencedByCount"] == 2
    assert details["sampleTruncated"] == true
    refute Jason.encode!(body) =~ hidden.doc_id
    refute Jason.encode!(body) =~ "Sibling project secret plan"
    assert Repo.get(MediaFile, file.id), "the hidden use must still block the delete"
  end

  test "a file used only where the caller cannot read is refused without naming anything",
       ctx do
    file = media_file!()
    hidden = using_doc!(file, ctx.sibling.id, "Only sibling secret")

    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@dataset}/#{file.id}")
      |> json_response(409)

    assert body["error"]["details"]["referencedBy"] == []
    refute Jason.encode!(body) =~ hidden.doc_id
    refute Jason.encode!(body) =~ "Only sibling secret"
    assert Repo.get(MediaFile, file.id)
  end
end
