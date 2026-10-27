defmodule BarkparkWeb.MediaDeleteRefFormsGuardTest do
  @moduledoc """
  task-cad26da17d51e41f: `Content.Query.list_reference_holders/3` now skips a
  type with no field that can hold a link. It also backs the media delete guard
  (`WhereUsed`), so these pin, through the guarded door, the reference forms the
  other guard tests do not: the companion `asset-…` id in a declared
  `reference` field as `{_ref}` and as a bare string, in a link array, in an
  image array item, a dataset that also holds link-less types, and a type whose
  schema gains the reference field after the document was written. Each
  refusal checks that the blob row survives.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-ref-forms-guard-admin"
  @ds "mediarefforms"

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "cover", "type" => "reference", "refType" => "sanity.imageAsset"},
    %{"name" => "assets", "type" => "arrayOf", "of" => %{"type" => "reference"}},
    %{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}}
  ]

  setup do
    {:ok, _} = Auth.create_token(@admin, "ref-forms-guard", "test", ["read", "write", "admin"])
    schema!("refforms_post", @fields)
    # Link-less types beside it: list_reference_holders skips these without a query.
    schema!("refforms_note", [%{"name" => "body", "type" => "text"}])

    schema!("refforms_tags", [
      %{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}}
    ])

    :ok
  end

  test "a reference field holding {_ref: asset-…} blocks the delete" do
    {file, asset} = media_file!()
    doc_id = publish!("refforms_post", %{"cover" => %{"_type" => "reference", "_ref" => asset}})
    assert_refused(file, doc_id)
  end

  test "a reference field holding the bare asset-… string blocks the delete" do
    {file, asset} = media_file!()
    doc_id = publish!("refforms_post", %{"cover" => asset})
    assert_refused(file, doc_id)
  end

  test "a link array holding the asset blocks the delete" do
    {file, asset} = media_file!()

    doc_id =
      publish!("refforms_post", %{
        "assets" => [%{"_key" => "a1", "_type" => "reference", "_ref" => asset}]
      })

    assert_refused(file, doc_id)
  end

  test "an image array item holding the companion asset-… id blocks the delete" do
    {file, asset} = media_file!()

    doc_id =
      publish!("refforms_post", %{
        "gallery" => [
          %{
            "_key" => "g1",
            "_type" => "image",
            "asset" => %{"_type" => "reference", "_ref" => asset}
          }
        ]
      })

    assert_refused(file, doc_id)
  end

  test "a type whose schema gains the reference field after the document exists blocks the delete" do
    {file, asset} = media_file!()
    schema!("refforms_late", [%{"name" => "title", "type" => "string"}])
    doc_id = publish!("refforms_late", %{"cover" => %{"_type" => "reference", "_ref" => asset}})

    # The field is declared now; the stored document is unchanged.
    schema!("refforms_late", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "cover", "type" => "reference", "refType" => "sanity.imageAsset"}
    ])

    assert_refused(file, doc_id)
  end

  test "an unreferenced asset in the same dataset still deletes" do
    {file, _asset} = media_file!()
    _ = publish!("refforms_note", %{"body" => "nothing here"})

    admin(scoped_conn())
    |> delete("/v1/media/#{@ds}/#{file.id}")
    |> json_response(200)

    refute Repo.get(MediaFile, file.id)
  end

  defp assert_refused(%MediaFile{} = file, doc_id) do
    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@ds}/#{file.id}")
      |> json_response(409)

    assert Repo.get(MediaFile, file.id), "the guard answered 409 but the blob row was deleted"
    referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])
    assert doc_id in referrers or Content.published_id(doc_id) in referrers
  end

  defp schema!(name, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
  end

  defp publish!(type, fields) do
    {:ok, draft} = Content.create_document(type, Map.put(fields, "title", "Ref forms"), @ds)
    {:ok, _} = Content.publish_document(draft.doc_id, type, @ds)
    draft.doc_id
  end

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  # Uploads a unique PNG; answers the blob and its companion's published id (asset-…).
  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "ref-forms-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "forms.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@ds}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)

    file = Repo.get!(MediaFile, created["id"])
    asset = Media.asset_doc_for_file(file, file.dataset, MediaFile.scope_opts(file))
    {file, Content.published_id(asset.doc_id)}
  end
end
