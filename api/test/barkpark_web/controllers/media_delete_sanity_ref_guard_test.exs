defmodule BarkparkWeb.MediaDeleteSanityRefGuardTest do
  @moduledoc """
  task-bace4f482af160a9 — a guarded media delete must also refuse when a
  document's image/file field holds the blob's SANITY-form ref:
  `image-<sha1>-<w>x<h>-<ext>`, `file-<sha1>-<ext>`, or the blob's
  `source_id`. The studio's LiveView save rewrites `asset-<uuid>` into the
  image form (`ImageMetadata.backfill/3`) and a Sanity import keeps Sanity's
  ids, and `Media.SanityAsset` serves either from this blob — but
  `WhereUsed.referrers/1` matched only the companion `asset-<uuid>`, so it
  answered 0 and the delete removed a blob a page still showed.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.WhereUsed
  alias Barkpark.Repo

  @admin "media-sanity-ref-guard-admin"
  @ds "mediasanityref"

  # 1x1 PNG; a unique trailer per upload keeps the assets distinct.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "sanity-ref-guard", "test", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sanityref_post",
          "title" => "Sanity Ref Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "hero", "type" => "image"},
            %{"name" => "attachment", "type" => "file"},
            %{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}}
          ]
        },
        @ds
      )

    :ok
  end

  test "an image field holding image-<sha1>-WxH-ext blocks the delete, as a draft too" do
    file = media_file!()
    # Only a draft holds it: a draft's reference is the same data loss.
    doc_id = draft!(%{"hero" => image("image-#{file.sha1}-1x1-png")})

    assert WhereUsed.referrers(file).count == 1
    assert_refused(file, doc_id)
  end

  test "a file field holding file-<sha1>-ext blocks the delete" do
    file = media_file!()
    doc_id = publish!(%{"attachment" => image("file-#{file.sha1}-png")})

    assert_refused(file, doc_id)
  end

  test "a ref equal to the blob's source_id blocks the delete, whatever its sha1" do
    file = media_file!()
    source_id = "image-#{String.duplicate("a", 40)}-640x480-jpg"
    file = file |> Ecto.Changeset.change(source_id: source_id) |> Repo.update!()
    doc_id = publish!(%{"hero" => image(source_id)})

    assert_refused(file, doc_id)
  end

  test "an image array item holding the Sanity id blocks the delete" do
    file = media_file!()

    doc_id =
      publish!(%{
        "gallery" => [Map.put(image("image-#{file.sha1}-1x1-png"), "_key", "g1")]
      })

    assert_refused(file, doc_id)
  end

  test "another blob's Sanity id does not block this one" do
    file = media_file!()
    other = String.duplicate("b", 40)
    publish!(%{"hero" => image("image-#{other}-1x1-png")})

    assert WhereUsed.referrers(file).count == 0
  end

  defp assert_refused(%MediaFile{} = file, doc_id) do
    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@ds}/#{file.id}")
      |> json_response(409)

    assert Repo.get(MediaFile, file.id), "the guard answered 409 but the blob row was deleted"
    assert body["error"]["details"]["referencedByCount"] == 1
    referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])
    # A draft-only holder is named by its draft id, a published one by its id.
    assert doc_id in referrers or Content.published_id(doc_id) in referrers
  end

  defp image(ref), do: %{"_type" => "image", "asset" => %{"_type" => "reference", "_ref" => ref}}

  defp draft!(fields) do
    {:ok, draft} =
      Content.create_document("sanityref_post", Map.put(fields, "title", "Sanity ref"), @ds)

    draft.doc_id
  end

  defp publish!(fields) do
    doc_id = draft!(fields)
    {:ok, _} = Content.publish_document(doc_id, "sanityref_post", @ds)
    doc_id
  end

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  defp media_file! do
    tmp =
      Path.join(System.tmp_dir!(), "sanity-ref-guard-#{System.unique_integer([:positive])}.png")

    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@ds}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)

    file = Repo.get!(MediaFile, created["id"])
    assert file.sha1 =~ ~r/\A[0-9a-f]{40}\z/
    file
  end
end
