defmodule Barkpark.MediaPathIsAPublishedReferenceTest do
  @moduledoc """
  `media_files.path` is a PUBLISHED REFERENCE, not a private storage detail
  (task-918106d49c62563e).

  ## Why this file exists

  The obvious way to dataset-key the blob keyspace is to stamp the prefix onto
  `media_files.path` as the bundle import COPYs rows. This test exists to prove,
  mechanically, that doing so BREAKS the bundle it is importing — so the prefix
  must be chosen at BIRTH (`Media.upload/3`) and an existing row's path must
  never be rewritten.

  The mechanism: `StudioLive`'s upload handler writes
  `"/media/files/\#{file.path}"` into the editor form and autosaves it, so a
  document's CONTENT persists the path as a literal string
  (`live/studio/studio_live/handlers/media.ex:54`). `MediaController.serve/2`
  then resolves that URL through `Media.get_file_by_path/2` — a lookup keyed on
  the very string that was persisted. Rewriting the row's `path` therefore
  orphans every document that already points at it, and a bundle carries BOTH
  the media row and the referencing document, so an import-time rewrite breaks
  its own payload.

  This is the fact that resolves the tension between "stamp the prefix onto
  media_files.path as it COPYs rows" and "NO existing media_files.path is
  rewritten": the second wins, because the first is a reference migration
  wearing a keyspace refactor's clothes.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @original_path "2026/08/referenced-asset.png"
  @rewritten_path "d/00000000-0000-0000-0000-0000000000ff/2026/08/referenced-asset.png"
  @bytes "REFERENCED-BYTES"

  setup do
    on_exit(fn ->
      _ = Blobstore.delete(@original_path)
      _ = Blobstore.delete(@rewritten_path)
    end)

    slug = "mediaref-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    raw = "mediaref-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, slug, "production", ["read"], ws.id)

    %{ws: ws, project: project, dataset: dataset, token: raw}
  end

  # The REAL scoped GET route, with the owning workspace's own membership — the
  # same route the exposure was proved on. Never a File.read.
  defp scoped_get(ctx, path) do
    scoped_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.token)
    |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/media/files/#{path}")
  end

  defp insert_row!(ctx, path) do
    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: Path.basename(path),
      original_name: Path.basename(path),
      path: path,
      mime_type: "image/png",
      size: byte_size(@bytes),
      dataset: "production",
      workspace_id: ctx.ws.id,
      project_id: ctx.project.id,
      dataset_id: ctx.dataset.id
    })
    |> Repo.insert!()
  end

  test "a document's CONTENT persists /media/files/<path> as a literal string", ctx do
    file = insert_row!(ctx, @original_path)

    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "ref-post-#{System.unique_integer([:positive])}",
          "title" => "Has an image",
          "content" => %{"image" => "/media/files/#{file.path}"}
        },
        "production",
        workspace_id: ctx.ws.id,
        project_id: ctx.project.id
      )

    stored = Repo.get!(Content.Document, doc.id)

    assert stored.content["image"] == "/media/files/#{@original_path}",
           "the reference is stored as a literal path string — this is what makes " <>
             "media_files.path a published reference rather than a storage detail"
  end

  test "rewriting an existing row's path 404s the URL that documents already hold", ctx do
    file = insert_row!(ctx, @original_path)
    assert {:ok, _p, _r} = Media.put_blob(@original_path, @bytes, workspace_id: ctx.ws.id)

    # BEFORE — the reference a document persisted resolves through the real
    # route and carries the right bytes.
    before = scoped_get(ctx, @original_path)
    assert before.status == 200
    assert before.resp_body == @bytes

    # The rewrite an import-time prefix stamp would perform.
    Repo.update!(Ecto.Changeset.change(file, path: @rewritten_path))

    resp = scoped_get(ctx, @original_path)

    assert resp.status == 404,
           "if a rewritten row still resolved at its OLD path, an import-time prefix " <>
             "stamp would be safe — it is not, and this is the proof"

    # And the row itself is now reachable only at its NEW path, which no
    # already-published document names.
    assert {:ok, _} = Media.get_file_by_path(@rewritten_path, workspace_id: ctx.ws.id)
    assert {:error, :not_found} = Media.get_file_by_path(@original_path, workspace_id: ctx.ws.id)
  end
end
