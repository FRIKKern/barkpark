defmodule BarkparkWeb.MediaDeleteMultiTypeArrayTest do
  @moduledoc """
  task-e7a8f98e6924df10: a media delete answered 500 in any dataset whose
  schemas hold an array field that allows several member types.

  Such a field stores `of` as a LIST of member definitions, for example
  `"of" => [%{"type" => "reference"}, %{"type" => "image"}]`. The where-used
  check in `Content.Query.list_reference_holders/3` read the member type with
  `get_in(field, ["of", "type"])`. On a list that call raises ArgumentError, so
  the delete crashed before it could answer. The workspace gyldendal-no has
  ten such fields, so every `bp media delete` there failed.

  The tests below upload a blob into a dataset with such a schema and check
  that the delete answers, and that a reference held inside a multi-type
  array still blocks it.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-multi-type-array-admin"
  @ds "mediamultiarr"

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "multi-type-array", "test", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "multiarr_page",
          "title" => "Multi-type array page",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "sections",
              "type" => "arrayOf",
              "of" => [
                %{"name" => "heading", "type" => "string"},
                %{"name" => "picture", "type" => "image"}
              ]
            },
            %{
              "name" => "related",
              "type" => "arrayOf",
              "of" => [
                %{"name" => "doc", "type" => "reference"},
                %{"name" => "note", "type" => "string"}
              ]
            },
            %{
              "name" => "mixed",
              "type" => "arrayOf",
              "of" => [
                %{"name" => "doc", "type" => "reference"},
                %{"name" => "picture", "type" => "image"}
              ]
            }
          ]
        },
        @ds
      )

    :ok
  end

  test "an unreferenced blob deletes with 200 when a schema has a multi-type array" do
    file = media_file!()

    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@ds}/#{file.id}")
      |> json_response(200)

    assert body["result"]["deleted"] == file.id
    refute Repo.get(MediaFile, file.id)
  end

  test "an image member of a multi-type array blocks the delete with 409" do
    file = media_file!()
    asset_doc_id = asset_doc_id!(file)

    {:ok, draft} =
      Content.create_document(
        "multiarr_page",
        %{
          "title" => "Image in sections",
          "sections" => [
            %{"_key" => "a", "_type" => "picture", "asset" => %{"_ref" => asset_doc_id}}
          ]
        },
        @ds
      )

    {:ok, _} = Content.publish_document(draft.doc_id, "multiarr_page", @ds)

    body =
      admin(scoped_conn())
      |> delete("/v1/media/#{@ds}/#{file.id}")
      |> json_response(409)

    assert Repo.get(MediaFile, file.id)
    referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])
    assert Content.published_id(draft.doc_id) in referrers
  end

  test "a reference member of a multi-type array blocks the delete with 409" do
    file = media_file!()
    asset_doc_id = asset_doc_id!(file)

    {:ok, draft} =
      Content.create_document(
        "multiarr_page",
        %{
          "title" => "Reference in related",
          "related" => [%{"_key" => "r", "_type" => "doc", "_ref" => asset_doc_id}]
        },
        @ds
      )

    {:ok, _} = Content.publish_document(draft.doc_id, "multiarr_page", @ds)

    admin(scoped_conn())
    |> delete("/v1/media/#{@ds}/#{file.id}")
    |> json_response(409)

    assert Repo.get(MediaFile, file.id)
  end

  # A field that allows a reference AND an image must check both shapes. The
  # old code picked one arm per field, so the image member went unchecked.
  test "an image member of an array that also allows references blocks the delete with 409" do
    file = media_file!()
    asset_doc_id = asset_doc_id!(file)

    {:ok, draft} =
      Content.create_document(
        "multiarr_page",
        %{
          "title" => "Image in mixed",
          "mixed" => [
            %{"_key" => "m", "_type" => "picture", "asset" => %{"_ref" => asset_doc_id}}
          ]
        },
        @ds
      )

    {:ok, _} = Content.publish_document(draft.doc_id, "multiarr_page", @ds)

    admin(scoped_conn())
    |> delete("/v1/media/#{@ds}/#{file.id}")
    |> json_response(409)

    assert Repo.get(MediaFile, file.id)
  end

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  defp media_file! do
    tmp =
      Path.join(System.tmp_dir!(), "multi-type-array-#{System.unique_integer([:positive])}.png")

    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@ds}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)

    Repo.get!(MediaFile, created["id"])
  end

  defp asset_doc_id!(%MediaFile{} = file) do
    doc = Media.asset_doc_for_file(file, file.dataset, MediaFile.scope_opts(file))
    assert doc
    Content.published_id(doc.doc_id)
  end
end
