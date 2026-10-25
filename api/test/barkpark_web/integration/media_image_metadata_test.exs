defmodule BarkparkWeb.Integration.MediaImageMetadataTest do
  @moduledoc """
  task-fd05a9327034f89c: an image upload stores what Sanity keeps as the
  asset's `metadata` — dimensions, lqip, blurHash, hasAlpha, isOpaque and the
  seven-swatch palette always; EXIF and location when the upload asks
  (`meta=exif,location`, Sanity's parameter). It is readable where Sanity's
  `asset->metadata` sits: the asset document's `metadata`, and the upload
  receipt's `asset.metadata`.

  Uses the `:image` dep's bundled libvips NIF, as the on-demand transform test
  does.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the media plugin owns mediaAsset, its upload hook and the media routes
  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "image-metadata", ["read", "write", "admin"])
    :ok
  end

  # 64 × 48 JPEG, a red field, with a camera make and an Oslo GPS position.
  defp jpeg_with_gps do
    {:ok, img} = Image.new(64, 48, color: [200, 30, 30])

    {:ok, img} =
      Vix.Vips.Image.mutate(img, fn m ->
        :ok = Vix.Vips.MutableImage.set(m, "exif-ifd0-Make", :gchararray, "Barkpark Cam")

        :ok =
          Vix.Vips.MutableImage.set(m, "exif-ifd3-GPSLatitude", :gchararray, "59/1 54/1 3600/100")

        :ok = Vix.Vips.MutableImage.set(m, "exif-ifd3-GPSLatitudeRef", :gchararray, "N")
        :ok = Vix.Vips.MutableImage.set(m, "exif-ifd3-GPSLongitude", :gchararray, "10/1 45/1 0/1")
        :ok = Vix.Vips.MutableImage.set(m, "exif-ifd3-GPSLongitudeRef", :gchararray, "E")
      end)

    path = Path.join(System.tmp_dir!(), "gps-#{System.unique_integer([:positive])}.jpg")
    {:ok, _} = Image.write(img, path, quality: 90)
    path
  end

  # 40 × 40 PNG with a half-transparent alpha band.
  defp translucent_png do
    {:ok, img} = Image.new(40, 40, color: [20, 120, 220, 128])
    path = Path.join(System.tmp_dir!(), "alpha-#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(img, path)
    path
  end

  defp upload(conn, path, filename, type, extra) do
    file = %Plug.Upload{path: path, filename: filename, content_type: type}

    created =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post(~p"/v1/media/production/upload", Map.put(extra, "file", file))
      |> json_response(201)

    %{"result" => %{"id" => id, "path" => stored}} = created

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), stored))
      Assets.delete_for_blob(id, "production")
    end)

    created["result"]
  end

  test "the default set, in Sanity's shape, on the asset document and in the receipt", %{
    conn: conn
  } do
    result = upload(conn, jpeg_with_gps(), "red.jpg", "image/jpeg", %{})
    meta = Assets.find_by_media_file_id(result["id"], "production").content["metadata"]

    assert meta["_type"] == "sanity.imageMetadata"

    assert meta["dimensions"] == %{
             "_type" => "sanity.imageDimensions",
             "width" => 64,
             "height" => 48,
             "aspectRatio" => 64 / 48
           }

    assert "data:image/jpeg;base64," <> _ = meta["lqip"]
    # A 5 × 4 hash on a landscape image, as Sanity's.
    assert "V" <> _ = meta["blurHash"]
    assert meta["hasAlpha"] == false
    assert meta["isOpaque"] == true
    assert meta["palette"]["_type"] == "sanity.imagePalette"
    assert meta["palette"]["dominant"]["foreground"] == "#fff"
    assert meta["palette"]["dominant"]["population"] == 100.0
    # Not asked for: no EXIF, no location.
    refute Map.has_key?(meta, "exif")
    refute Map.has_key?(meta, "location")

    assert result["asset"]["metadata"] == meta
  end

  test "meta=exif,location adds the EXIF tags and the GPS position", %{conn: conn} do
    result = upload(conn, jpeg_with_gps(), "gps.jpg", "image/jpeg", %{"meta" => "exif,location"})
    meta = Assets.find_by_media_file_id(result["id"], "production").content["metadata"]

    assert meta["exif"]["_type"] == "sanity.imageExifMetadata"
    assert meta["exif"]["Make"] == "Barkpark Cam"
    assert meta["location"] == %{"_type" => "geopoint", "lat" => 59.91, "lng" => 10.75}
  end

  test "an image with see-through pixels has alpha and is not opaque", %{conn: conn} do
    result = upload(conn, translucent_png(), "alpha.png", "image/png", %{})
    meta = Assets.find_by_media_file_id(result["id"], "production").content["metadata"]

    assert meta["hasAlpha"] == true
    assert meta["isOpaque"] == false
  end
end
