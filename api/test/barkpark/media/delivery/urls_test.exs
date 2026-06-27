defmodule Barkpark.Media.Delivery.UrlsTest do
  # async: false — original_url / thumbnail_url / rendition_urls call Cdn.public_url,
  # which reads the global :media_cdn Application env. We reset it in setup to avoid
  # races with cdn_test.exs, which also toggles that env.
  use ExUnit.Case, async: false

  alias Barkpark.Media.Delivery.Urls
  alias Barkpark.Media.Storage.MediaFile

  setup do
    original = Application.get_env(:barkpark, :media_cdn)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :media_cdn)
        val -> Application.put_env(:barkpark, :media_cdn, val)
      end
    end)

    # Ensure no CDN prefix so URLs are plain relative paths (easier to assert).
    Application.delete_env(:barkpark, :media_cdn)
    :ok
  end

  defp image_file do
    %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/06/photo.jpg",
      mime_type: "image/jpeg"
    }
  end

  defp non_image_file do
    %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/06/document.pdf",
      mime_type: "application/pdf"
    }
  end

  describe "original_url/2" do
    test "returns path under /media/files/ for image file" do
      file = image_file()
      assert Urls.original_url(file) == "/media/files/2026/06/photo.jpg"
    end

    test "returns path under /media/files/ for non-image file" do
      file = non_image_file()
      assert Urls.original_url(file) == "/media/files/2026/06/document.pdf"
    end

    test "prepends scope_prefix when provided" do
      file = image_file()
      url = Urls.original_url(file, scope_prefix: "/w/ws1/p/proj1")
      assert url == "/w/ws1/p/proj1/media/files/2026/06/photo.jpg"
    end
  end

  describe "thumbnail_url/2" do
    test "returns rendition URL for image files" do
      file = image_file()
      url = Urls.thumbnail_url(file)
      assert url =~ "/media/renditions/#{file.id}/thumb"
    end

    test "falls back to original URL for non-image files" do
      file = non_image_file()
      assert Urls.thumbnail_url(file) == Urls.original_url(file)
    end
  end

  describe "preview_url/2" do
    test "returns rendition URL for image files" do
      file = image_file()
      url = Urls.preview_url(file)
      assert url =~ "/media/renditions/#{file.id}/preview"
    end

    test "falls back to original URL for non-image files" do
      file = non_image_file()
      assert Urls.preview_url(file) == Urls.original_url(file)
    end
  end

  describe "rendition_urls/2" do
    test "returns a map with all preset keys for image files" do
      file = image_file()
      urls = Urls.rendition_urls(file)
      assert is_map(urls)
      assert map_size(urls) > 0
      assert Map.has_key?(urls, "thumb")
      assert Map.has_key?(urls, "preview")
    end

    test "every value contains the file id" do
      file = image_file()
      urls = Urls.rendition_urls(file)

      Enum.each(urls, fn {_preset, url} ->
        assert url =~ file.id
      end)
    end

    test "returns empty map for non-image files" do
      file = non_image_file()
      assert Urls.rendition_urls(file) == %{}
    end
  end

  describe "etag_for/1" do
    test "returns unknown etag for a missing path" do
      assert Urls.etag_for("/tmp/barkpark-nonexistent-#{System.unique_integer()}.bin") ==
               "\"unknown\""
    end

    test "returns a quoted size-mtime etag for an existing file" do
      path = "/tmp/barkpark_urls_test_#{System.unique_integer()}.tmp"
      File.write!(path, "hello")

      on_exit(fn -> File.rm(path) end)

      etag = Urls.etag_for(path)
      assert etag =~ ~r/^"\d+-[0-9A-Z]+"$/
    end

    test "etag changes when file content changes" do
      path = "/tmp/barkpark_urls_test_change_#{System.unique_integer()}.tmp"
      File.write!(path, "version1")
      on_exit(fn -> File.rm(path) end)

      etag1 = Urls.etag_for(path)

      # Touch the file with different content (size differs → different etag)
      :timer.sleep(1100)
      File.write!(path, "version2-longer")

      etag2 = Urls.etag_for(path)
      assert etag1 != etag2
    end
  end
end
