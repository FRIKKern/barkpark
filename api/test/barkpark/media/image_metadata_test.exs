defmodule Barkpark.Media.ImageMetadataTest do
  @moduledoc """
  Gyldendal parity E1.7 (task-e2eab81cc3e87047): a schema-declared `image`
  value saved without its denormalised metadata is back-filled from the media
  asset — `url` / `width` / `height` from the asset document's `fileInfo` (or
  the blob, probed), `lqip` from the `lqip` rendition — and nothing already
  present is ever overwritten.

  The rendition backend is stubbed (as in RenditionsTest) so the test does
  not need libvips: the `lqip` rendition is whatever bytes the stub writes,
  which is exactly what the data: URI must carry.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Media.ImageMetadata
  alias Barkpark.Media
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @dataset "production"

  # 1×1 PNG — enough for Probe.probe/2 to read the IHDR dimensions.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  defmodule OkBackend do
    @behaviour Barkpark.Media.ImageBackend
    @impl true
    def render(_src, dest, _spec, _watermark) do
      File.write!(dest, "tiny-jpeg-bytes")
      :ok
    end

    @impl true
    def available?, do: true
  end

  setup do
    original = Application.get_env(:barkpark, :image_backend)
    Application.put_env(:barkpark, :image_backend, OkBackend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)

    :ok
  end

  # A persisted blob with a companion mediaAsset document. `with_dims` decides
  # whether the asset document's fileInfo already carries width/height (the
  # post-processing shape) or the blank strings a fresh upload has.
  defp fixture(opts \\ []) do
    token = Ecto.UUID.generate()
    rel = Path.join("test-blobs", "#{token}.png")
    abs = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, @png)

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        mime_type: "image/png",
        path: rel,
        original_name: "cover.png",
        filename: "cover.png",
        size: byte_size(@png),
        dataset: @dataset
      })
      |> Repo.insert()

    {:ok, doc} = Assets.ensure_for_upload(file)

    doc =
      if Keyword.get(opts, :with_dims, true) do
        fi = Map.merge(doc.content["fileInfo"], %{"width" => "1600", "height" => "2527"})

        {:ok, updated} =
          Content.upsert_document(
            "mediaAsset",
            %{
              "doc_id" => doc.doc_id,
              "title" => doc.title,
              "status" => doc.status,
              "content" => Map.put(doc.content, "fileInfo", fi)
            },
            @dataset,
            source: :api
          )

        updated
      else
        doc
      end

    on_exit(fn ->
      File.rm(abs)
      Renditions.delete_for_file(file.id)
    end)

    {file, doc}
  end

  describe "backfill/3" do
    test "fills url, width, height and lqip from the asset, as numbers and a data: URI" do
      {file, _doc} = fixture()

      out = ImageMetadata.backfill(%{"assetId" => file.id, "alt" => "Cover"}, @dataset, [])

      assert out["url"] == "/media/files/#{file.path}"
      assert out["width"] == 1600
      assert out["height"] == 2527
      assert out["lqip"] == "data:image/jpeg;base64," <> Base.encode64("tiny-jpeg-bytes")
      assert out["alt"] == "Cover"
      assert out["assetId"] == file.id
    end

    test "accepts the asset document id spelling and never overwrites present values" do
      {file, _doc} = fixture()

      posted = %{
        "assetId" => "asset-#{file.id}",
        "url" => "/keep/this.jpg",
        "width" => 10,
        "height" => 20,
        "lqip" => "data:image/jpeg;base64,KEEP",
        "alt" => ""
      }

      assert ImageMetadata.backfill(posted, @dataset, []) == posted
    end

    test "probes the blob when the asset document has no dimensions yet" do
      {file, _doc} = fixture(with_dims: false)

      out = ImageMetadata.backfill(%{"assetId" => file.id}, @dataset, [])

      assert out["width"] == 1
      assert out["height"] == 1
      assert is_binary(out["lqip"])
    end

    test "an unknown asset, a bare URL and a map without assetId pass through byte-identically" do
      unknown = %{"assetId" => Ecto.UUID.generate(), "alt" => "x"}
      assert ImageMetadata.backfill(unknown, @dataset, []) == unknown
      assert ImageMetadata.backfill("/media/files/x.jpg", @dataset, []) == "/media/files/x.jpg"
      assert ImageMetadata.backfill(%{"url" => "/x.jpg"}, @dataset, []) == %{"url" => "/x.jpg"}
      assert ImageMetadata.backfill(nil, @dataset, []) == nil
    end
  end

  describe "backfill_params/4 walks the declared schema" do
    test "top-level image, arrayOf image, and image subfields of composite rows; other fields untouched" do
      {file, _doc} = fixture()

      schema = %{
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "cover", "type" => "image"},
          %{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}},
          %{
            "name" => "banners",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{"name" => "title", "type" => "string"},
                %{"name" => "backgroundImage", "type" => "image"}
              ]
            }
          },
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      }

      params = %{
        "title" => "Forside",
        "cover" => %{"assetId" => file.id, "alt" => "A"},
        "gallery" => [%{"assetId" => file.id}, "/media/files/legacy.jpg"],
        "banners" => [%{"title" => "Card", "backgroundImage" => %{"assetId" => file.id}}],
        "author" => "author-1"
      }

      out = ImageMetadata.backfill_params(params, schema, @dataset, [])

      assert out["title"] == "Forside"
      assert out["author"] == "author-1"
      assert out["cover"]["width"] == 1600 and out["cover"]["alt"] == "A"
      assert [first, "/media/files/legacy.jpg"] = out["gallery"]
      assert first["height"] == 2527 and is_binary(first["lqip"])
      assert [%{"title" => "Card", "backgroundImage" => bg}] = out["banners"]
      assert bg["width"] == 1600 and bg["url"] == "/media/files/#{file.path}"
    end

    test "a nil schema or non-map params pass through" do
      params = %{"cover" => %{"assetId" => "x"}}
      assert ImageMetadata.backfill_params(params, nil, @dataset, []) == params
      assert ImageMetadata.backfill_params("nope", %{fields: []}, @dataset, []) == "nope"
    end
  end

  test "the lqip rendition preset exists and stays tiny" do
    assert "lqip" in Renditions.presets()
  end
end
