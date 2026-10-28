defmodule Barkpark.Media.TransformOutputMetadataTest do
  @moduledoc """
  task-8b11ad4f02f32ee9: a transform drops the original's EXIF in every
  format, and a JPEG is written with optimised Huffman tables, as Sanity's CDN
  writes it.

  On main `strip_metadata` reached libvips as `strip`, which libvips 8.15
  replaced with `keep`: a camera's EXIF (make, GPS) passed into every public
  derivative, and a JPEG was about 60% larger than Sanity's for the same pixels.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.Transform
  alias Elixir.Vix.Vips.{MutableImage, Operation}

  setup do
    if Vix.available?(), do: :ok, else: {:skip, "no libvips on this host"}
  end

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "meta-#{System.unique_integer([:positive])}.#{ext}")

  # A JPEG whose EXIF names the camera.
  defp source! do
    {:ok, noise} = Operation.gaussnoise(320, 200, sigma: 30.0, mean: 128.0)
    {:ok, rgb} = Operation.bandjoin([noise, noise, noise])
    {:ok, rgb} = Operation.cast(rgb, :VIPS_FORMAT_UCHAR)
    # Attaches libvips' built-in sRGB profile as the image's ICC profile.
    {:ok, rgb} = Operation.icc_transform(rgb, "srgb", input_profile: "srgb")

    {:ok, tagged} =
      Elixir.Vix.Vips.Image.mutate(rgb, fn m ->
        MutableImage.set(
          m,
          "exif-ifd0-Make",
          :gchararray,
          "SecretCam (SecretCam, ASCII, 10 components, 10 bytes)"
        )
      end)

    src = tmp("jpg")

    :ok =
      Operation.jpegsave(tagged, src,
        Q: 90,
        keep: [:VIPS_FOREIGN_KEEP_EXIF, :VIPS_FOREIGN_KEEP_ICC]
      )

    assert File.read!(src) =~ "SecretCam"
    src
  end

  test "no format carries the original's EXIF; each keeps its ICC profile" do
    src = source!()

    for fm <- if(Vix.avif?(), do: ~w(jpg png webp avif), else: ~w(jpg png webp)) do
      dest = tmp(fm)
      {:ok, plan} = Transform.parse(%{"w" => "160", "fm" => fm})
      assert :ok = Vix.transform(src, dest, plan, nil)
      refute File.read!(dest) =~ "SecretCam", "#{fm} kept the EXIF"
      {:ok, out} = Image.open(dest)
      {:ok, fields} = Elixir.Vix.Vips.Image.header_field_names(out)
      assert "icc-profile-data" in fields, "#{fm} lost the ICC profile"
    end
  end

  test "a JPEG is written with optimised Huffman tables" do
    src = source!()
    dest = tmp("jpg")
    {:ok, plan} = Transform.parse(%{"w" => "160", "fm" => "jpg", "q" => "75"})
    assert :ok = Vix.transform(src, dest, plan, nil)

    {:ok, image} = Image.open(dest)
    {:ok, plain} = Operation.jpegsave_buffer(image, Q: 75, keep: [])
    assert File.stat!(dest).size < byte_size(plain)
  end
end
