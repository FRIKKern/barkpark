defmodule BarkparkWeb.Integration.MediaDeleteRecheckRaceTest do
  @moduledoc """
  task-bc53aa9e49742ded: a media delete's where-used check and the delete are one
  transaction. The doors ask `WhereUsed` first, but a reference written between that
  answer and the delete used to slip through and leave a dangling image. The
  unforced `:guard` delete now asks again inside the transaction, under a lock on the
  file row, and refuses with the same 409 census.

  The race is made deterministic by writing the reference exactly in that window:
  after the door's check answered "unreferenced", before `Media.delete_file/2`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Media, Tenancy}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.WhereUsed
  alias Barkpark.Repo

  @ds "media-delete-recheck"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @pdf "%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"

  setup %{conn: conn} do
    ws = create_workspace!("media-recheck-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {_default_ws, default_proj} = ensure_default_scope!()

    # Guerrilla's shape: the Default project has a dataset of the SAME name.
    {:ok, _} = Tenancy.get_or_create_dataset(default_proj, @ds)

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "mainImage", "type" => "image"},
            %{"name" => "attachment", "type" => "file"}
          ]
        },
        @ds,
        scope
      )

    raw = "media-recheck-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "member", @ds, ["read", "write"], ws.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("x-requested-with", "bp-media-picker")

    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}"

  defp upload!(conn, ws, proj, filename, content_type, bytes) do
    tmp = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, bytes)
    upload = %Plug.Upload{path: tmp, filename: filename, content_type: content_type}

    resp = post(conn, base(ws, proj) <> "/upload", %{"file" => upload})
    assert resp.status in [200, 201], "upload failed: #{resp.status} #{resp.resp_body}"
    result = Jason.decode!(resp.resp_body)["result"]

    on_exit(fn ->
      case Repo.get(MediaFile, result["id"]) do
        %MediaFile{path: path} when is_binary(path) ->
          File.rm(Path.join(Media.upload_dir(), path))

        _ ->
          :ok
      end
    end)

    # The live precondition: the companion asset doc exists only as a draft.
    assert "drafts.asset-" <> _ = result["assetDocId"]
    {result["id"], Content.published_id(result["assetDocId"])}
  end

  defp png, do: Base.decode64!(@png_b64)

  defp refer!(scope, ref) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"title" => "written mid-delete", "mainImage" => %{"asset" => %{"_ref" => ref}}},
        @ds,
        scope
      )

    doc
  end

  test "a reference written after the door's check refuses the delete (409 census, nothing deleted)",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {png_id, png_ref} = upload!(conn, ws, proj, "pixel.png", "image/png", png())
    {:ok, file} = Media.get_file(png_id, scope)

    # The door's own check: nothing refers to it yet.
    assert %{count: 0} = WhereUsed.referrers(file)

    # The race: a reference lands in the window before the delete.
    doc = refer!(scope, png_ref)

    assert {:error, {:referenced, %MediaFile{id: ^png_id}, %{count: 1} = census}} =
             Media.delete_file(png_id, scope ++ [where_used: :guard, override: nil])

    assert Repo.get(MediaFile, png_id), "refused, but the row is gone"
    assert {:ok, _} = Media.get_file(png_id, scope)

    # The doors render it as their own check does: 409, the referrer named.
    body =
      conn
      |> BarkparkWeb.FallbackController.call({:error, {:referenced, file, census}})
      |> json_response(409)

    assert body["error"]["details"]["referencedByCount"] == 1
    assert [%{"doc_id" => doc_id}] = body["error"]["details"]["referencedBy"]
    assert doc_id == doc.doc_id
  end

  test "unreferenced, the guarded delete goes through; forced and cascade never re-check",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {a, _} = upload!(conn, ws, proj, "a.png", "image/png", png())

    assert {:ok, %MediaFile{id: ^a}} =
             Media.delete_file(a, scope ++ [where_used: :guard, override: nil])

    refute Repo.get(MediaFile, a)

    # A forced delete (the door passes its witness) and a cascade delete a referenced file.
    {b, b_ref} = upload!(conn, ws, proj, "b.png", "image/png", png())
    refer!(scope, b_ref)

    assert {:ok, _} =
             Media.delete_file(
               b,
               scope ++ [where_used: :guard, override: %{forced: true, referencedByCount: 1}]
             )

    {c, c_ref} = upload!(conn, ws, proj, "c.png", "image/png", png())
    refer!(scope, c_ref)
    assert {:ok, _} = Media.delete_file(c, scope ++ [where_used: :cascade])
  end

  test "through the door: a referenced file is still 409 and an unreferenced one deletes",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {kept, ref} = upload!(conn, ws, proj, "kept.png", "image/png", png())
    refer!(scope, ref)
    assert conn |> delete(base(ws, proj) <> "/#{kept}") |> json_response(409)
    assert Repo.get(MediaFile, kept)

    # Different bytes: an identical upload is the same file (de-duplicated).
    {gone, _} = upload!(conn, ws, proj, "gone.pdf", "application/pdf", @pdf)

    assert %{"result" => %{"deleted" => ^gone}} =
             conn |> delete(base(ws, proj) <> "/#{gone}") |> json_response(200)
  end
end
