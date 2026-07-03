defmodule Barkpark.Media.RenditionsTest do
  # async: false — toggles the global :image_backend Application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Media
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile

  # Stub backend that always succeeds by writing a placeholder byte to `dest`.
  defmodule OkBackend do
    @behaviour Barkpark.Media.ImageBackend
    @impl true
    def render(_src, dest, _spec, _watermark) do
      File.write!(dest, "rendition")
      :ok
    end

    @impl true
    def available?, do: true
  end

  # Stub backend that reproduces the libvips/ARM failure the gate must avoid
  # ever reaching for non-raster mimes.
  defmodule FailBackend do
    @behaviour Barkpark.Media.ImageBackend
    @impl true
    def render(_src, _dest, _spec, _watermark),
      do: {:error, %{__struct__: Image.Error, message: "Failed to find load"}}

    @impl true
    def available?, do: true
  end

  setup do
    original = Application.get_env(:barkpark, :image_backend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)

    :ok
  end

  defp file(mime, ext) do
    id = Ecto.UUID.generate()
    rel = Path.join("test-blobs", "#{id}.#{ext}")
    abs = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "blob-bytes")

    on_exit(fn ->
      File.rm(abs)
      Renditions.delete_for_file(id)
    end)

    %MediaFile{
      id: id,
      mime_type: mime,
      path: rel,
      original_name: "x.#{ext}",
      filename: "x.#{ext}"
    }
  end

  describe "generate_all/2 gates on the raster set" do
    test "SVG blob generates no rendition and logs no 'Failed to find load'" do
      Application.put_env(:barkpark, :image_backend, FailBackend)
      svg = file("image/svg+xml", "svg")

      log =
        capture_log(fn ->
          assert Renditions.generate_all(svg) == :ok
        end)

      refute log =~ "Failed to find load"
      # No preset file was written (the backend was never invoked).
      for preset <- Renditions.presets() do
        assert Renditions.relative_path(svg, preset) == nil
      end
    end

    test "TIFF blob is skipped cleanly (no backend call, no error log)" do
      Application.put_env(:barkpark, :image_backend, FailBackend)
      tiff = file("image/tiff", "tiff")

      log = capture_log(fn -> assert Renditions.generate_all(tiff) == :ok end)

      refute log =~ "Failed to find load"
    end

    test "PNG blob generates renditions for every preset" do
      Application.put_env(:barkpark, :image_backend, OkBackend)
      png = file("image/png", "png")

      assert Renditions.generate_all(png) == :ok

      for preset <- Renditions.presets() do
        assert Renditions.relative_path(png, preset) != nil
      end
    end

    test "PNG whose entire rendition set fails returns {:error, :all_renditions_failed}" do
      Application.put_env(:barkpark, :image_backend, FailBackend)
      png = file("image/png", "png")

      log =
        capture_log(fn ->
          assert Renditions.generate_all(png) == {:error, :all_renditions_failed}
        end)

      # A raster image that truly fails DOES surface the warning — that path is
      # legitimate; the fix is only that non-raster mimes never reach it.
      assert log =~ "Failed to find load"
    end
  end
end
