defmodule Barkpark.Plugins.Media.AssetsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Media.Assets

  @dataset "production"

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} =
      Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})

    Barkpark.Plugins.Media.Codelists.seed_all()
    :ok
  end

  describe "ensure_for_upload/1" do
    test "creates a draft mediaAsset linked to the blob" do
      temp = write_temp!("photo.jpg", "fake jpeg bytes")

      assert {:ok, file} =
               Media.upload(
                 %Plug.Upload{
                   path: temp,
                   filename: "photo.jpg",
                   content_type: "image/jpeg"
                 },
                 @dataset
               )

      assert {:ok, doc} = Assets.ensure_for_upload(file)
      assert doc.type == "mediaAsset"
      assert doc.title == "photo.jpg"
      assert String.starts_with?(doc.doc_id, "drafts.asset-")

      assert doc.content["mediaFileId"] == file.id
      assert doc.content["bp_asset_kind"] == "image"
      assert doc.content["fileInfo"]["url"] == "/media/files/#{file.path}"
      assert doc.content["fileInfo"]["mimeType"] == "image/jpeg"
    end

    test "is idempotent for the same blob" do
      temp = write_temp!("dup.png", "png")

      {:ok, file} =
        Media.upload(
          %Plug.Upload{path: temp, filename: "dup.png", content_type: "image/png"},
          @dataset
        )

      assert {:ok, first} = Assets.ensure_for_upload(file)
      assert {:ok, second} = Assets.ensure_for_upload(file)
      assert first.id == second.id
    end
  end

  describe "upload hook via Registry" do
    test "Media.upload auto-creates the asset document when plugin is loaded" do
      temp = write_temp!("hook.pdf", "%PDF-1.4")

      assert {:ok, file} =
               Media.upload(
                 %Plug.Upload{
                   path: temp,
                   filename: "hook.pdf",
                   content_type: "application/pdf"
                 },
                 @dataset
               )

      doc = Assets.find_by_media_file_id(file.id, @dataset)
      assert doc
      assert doc.content["bp_asset_kind"] == "document"
    end
  end

  describe "query API" do
    test "mediaAsset documents are listable via Content.list_documents/3" do
      temp = write_temp!("listed.webp", "webp")

      {:ok, file} =
        Media.upload(
          %Plug.Upload{path: temp, filename: "listed.webp", content_type: "image/webp"},
          @dataset
        )

      _ = Assets.ensure_for_upload(file)

      docs =
        Content.list_documents("mediaAsset", @dataset,
          perspective: :drafts,
          filter_map: %{"bp_asset_kind" => %{"eq" => "image"}}
        )

      assert Enum.any?(docs, &(&1.content["mediaFileId"] == file.id))
    end
  end

  describe "codelists" do
    test "seed_all registers asset role and license lists" do
      assert %{label: "Cover"} =
               Barkpark.Content.Codelists.lookup("media", "media:asset_role", "cover")

      assert %{label: "CC BY"} =
               Barkpark.Content.Codelists.lookup("media", "media:license", "cc-by")
    end
  end

  describe "delete_for_blob/2" do
    test "removes linked mediaAsset documents when blob is deleted" do
      temp = write_temp!("gone.gif", "gif")

      {:ok, file} =
        Media.upload(
          %Plug.Upload{path: temp, filename: "gone.gif", content_type: "image/gif"},
          @dataset
        )

      assert Assets.find_by_media_file_id(file.id, @dataset)

      assert {:ok, _} = Media.delete_file(file.id, where_used: :cascade)
      refute Assets.find_by_media_file_id(file.id, @dataset)
    end
  end

  describe "backfill/2" do
    test "creates documents only for blobs missing asset docs" do
      temp1 = write_temp!("bf1.jpg", "jpg1")
      temp2 = write_temp!("bf2.jpg", "jpg2")

      {:ok, file1} =
        Media.upload(
          %Plug.Upload{path: temp1, filename: "bf1.jpg", content_type: "image/jpeg"},
          @dataset
        )

      {:ok, file2} =
        Media.upload(
          %Plug.Upload{path: temp2, filename: "bf2.jpg", content_type: "image/jpeg"},
          @dataset
        )

      # file1 already has a doc from upload hook; remove it to simulate legacy blob
      Assets.delete_for_blob(file1.id, @dataset)
      refute Assets.find_by_media_file_id(file1.id, @dataset)
      assert Assets.find_by_media_file_id(file2.id, @dataset)

      assert {:ok, stats} = Assets.backfill(@dataset)
      assert stats.created == 1
      assert stats.skipped == 1
      assert stats.errors == []

      assert Assets.find_by_media_file_id(file1.id, @dataset)
    end

    test "dry-run counts without inserting" do
      temp = write_temp!("dry.jpg", "jpg")

      {:ok, file} =
        Media.upload(
          %Plug.Upload{path: temp, filename: "dry.jpg", content_type: "image/jpeg"},
          @dataset
        )

      Assets.delete_for_blob(file.id, @dataset)

      assert {:ok, stats} = Assets.backfill(@dataset, dry_run: true)
      assert stats.created == 1
      refute Assets.find_by_media_file_id(file.id, @dataset)
    end
  end

  defp write_temp!(name, body) do
    path =
      Path.join(System.tmp_dir!(), "media-test-#{System.unique_integer([:positive])}-#{name}")

    File.write!(path, body)
    path
  end
end
