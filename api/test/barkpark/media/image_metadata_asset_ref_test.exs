defmodule Barkpark.Media.ImageMetadataAssetRefTest do
  @moduledoc """
  task-7ea6f41cede5ee97: an image field in Sanity's shape,
  `{_type, asset: {_ref, _type: "reference"}, hotspot, crop}`, keeps that
  shape when an editor picks or uploads an image. The Studio picker points the
  pick at the Barkpark asset document (`asset-<blob id>`); the save writes the
  id a Sanity reader follows: the media file's `source_id` when it is a Sanity
  image id, else `image-<sha1>-<w>x<h>-<ext>` from the stored bytes.

  On main the clause did not exist: the value was saved with
  `asset._ref: "asset-<blob id>"`, which `@sanity/image-url` refuses and GROQ
  `asset->url` cannot follow to a Sanity asset document.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.ImageMetadata
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @dataset "production"

  # 1×1 PNG, the same fixture ImageMetadataTest probes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  defp fixture(attrs) do
    token = Ecto.UUID.generate()
    rel = Path.join("test-blobs", "#{token}.png")
    abs = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, @png)

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(
        Map.merge(
          %{
            mime_type: "image/png",
            path: rel,
            original_name: "cover.png",
            filename: "cover.png",
            size: byte_size(@png),
            dataset: @dataset,
            sha1: :crypto.hash(:sha, @png) |> Base.encode16(case: :lower)
          },
          attrs
        )
      )
      |> Repo.insert()

    {:ok, _doc} = Assets.ensure_for_upload(file)
    on_exit(fn -> File.rm(abs) end)
    file
  end

  defp sanity_value(ref) do
    %{
      "_type" => "imageAsset",
      "alt" => "Lærelyst kan læres",
      "caption" => "Foto: Gyldendal",
      "asset" => %{"_ref" => ref, "_type" => "reference"}
    }
  end

  test "a pick of an imported Sanity image writes its Sanity id" do
    sanity_id = "image-2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366-jpg"
    file = fixture(%{})
    {:ok, file} = Media.set_source_id(file, sanity_id)

    out = ImageMetadata.backfill(sanity_value("asset-" <> file.id), @dataset, [])

    assert out["asset"] == %{"_ref" => sanity_id, "_type" => "reference"}
    assert out["alt"] == "Lærelyst kan læres"
    assert out["caption"] == "Foto: Gyldendal"
    assert out["_type"] == "imageAsset"
    refute Map.has_key?(out, "url"), "the reference shape gains no url"
    refute Map.has_key?(out, "assetId"), "the reference shape gains no assetId"
  end

  test "a fresh upload gets image-<sha1>-<w>x<h>-<ext> from its bytes" do
    file = fixture(%{})

    out = ImageMetadata.backfill(sanity_value("drafts.asset-" <> file.id), @dataset, [])

    assert out["asset"]["_ref"] == "image-#{file.sha1}-1x1-png"
    assert out["asset"]["_type"] == "reference"
  end

  test "a Sanity id is kept, and a blob that does not exist leaves the value as posted" do
    kept = sanity_value("image-917cdfa94037b90600d868383cd1f27ea690b55b-1000x667-jpg")
    assert ImageMetadata.backfill(kept, @dataset, []) == kept

    missing = sanity_value("asset-" <> Ecto.UUID.generate())
    assert ImageMetadata.backfill(missing, @dataset, []) == missing
  end

  test "backfill_params walks a top-level image, a composite image and an image array" do
    file = fixture(%{})

    schema = %{
      fields: [
        %{"name" => "heroImage", "type" => "image"},
        %{
          "name" => "seo",
          "type" => "composite",
          "fields" => [%{"name" => "ogImage", "type" => "image"}]
        },
        %{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}}
      ]
    }

    picked = sanity_value("asset-" <> file.id)
    want = "image-#{file.sha1}-1x1-png"

    out =
      ImageMetadata.backfill_params(
        %{"heroImage" => picked, "seo" => %{"ogImage" => picked}, "gallery" => [picked]},
        schema,
        @dataset,
        []
      )

    assert out["heroImage"]["asset"]["_ref"] == want
    assert out["seo"]["ogImage"]["asset"]["_ref"] == want
    assert [%{"asset" => %{"_ref" => ^want}}] = out["gallery"]
  end
end
