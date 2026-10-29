defmodule Barkpark.Media.LqipSanityTest do
  @moduledoc """
  task-057b95c7e1bb58ff: the `lqip` placeholder is what Sanity's is: 20 px
  wide, a PNG for a PNG or GIF source and a JPEG otherwise. Sanity, read
  29 Oct: its 30 e2e-local PNG assets carry a 20x13 PNG (640x400 source) and
  its one production JPEG asset a 20x11 JPEG (320x179 source).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile
  alias Elixir.Vix.Vips.Operation

  setup do
    if Vix.available?(), do: :ok, else: {:skip, "no libvips on this host"}
  end

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "lqip-#{System.unique_integer([:positive])}.#{ext}")

  defp lqip!(mime, w, h) do
    {ext, save} =
      case mime do
        "image/png" -> {"png", &Operation.pngsave/2}
        "image/jpeg" -> {"jpg", &Operation.jpegsave/2}
      end

    src = tmp(ext)
    {:ok, img} = Image.new(w, h, color: [40, 120, 200])
    :ok = save.(img, src)
    spec = Renditions.spec_for(%MediaFile{mime_type: mime}, "lqip")
    dest = tmp(spec.format)
    assert :ok = Vix.render(src, dest, spec, nil)
    {:ok, out} = Image.open(dest)
    {spec.format, Image.width(out), Image.height(out)}
  end

  test "20 px wide, PNG for a PNG source and JPEG for a JPEG source" do
    assert lqip!("image/png", 640, 400) == {"png", 20, 13}
    assert lqip!("image/jpeg", 320, 179) == {"jpg", 20, 11}
    assert Renditions.spec_for(%MediaFile{mime_type: "image/gif"}, "lqip").format == "png"
    assert Renditions.spec_for(%MediaFile{mime_type: "image/png"}, "thumb").format == "jpg"
  end
end
