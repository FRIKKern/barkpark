defmodule Barkpark.Media.PadBgSanityTest do
  @moduledoc """
  task-da6a60b6d5e649f8: `pad` and a translucent `bg` render as Sanity's CDN
  renders them. Measured on Sanity with a 640x400 source: `w=200&pad=10` is
  200x132 (on main Barkpark answered 220x145), and `fit=fill&bg=80ff0000` to a
  PNG keeps the colour's alpha (main filled opaque red).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.Transform
  alias Elixir.Vix.Vips.Operation

  setup do
    if Vix.available?(), do: :ok, else: {:skip, "no libvips on this host"}
  end

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "padbg-#{System.unique_integer([:positive])}.#{ext}")

  defp render!(params) do
    src = tmp("png")
    {:ok, img} = Image.new(640, 400, color: [40, 120, 200])
    :ok = Operation.pngsave(img, src)
    {:ok, plan} = Transform.parse(params)
    dest = tmp(plan.fm)
    assert :ok = Vix.transform(src, dest, plan, nil)
    {:ok, out} = Image.open(dest)
    out
  end

  # The image is 180 x 112.5 inside the padding: Sanity floors to 112, Barkpark
  # rounds to 113, as for any one-sided resize.
  test "pad sits inside w" do
    out = render!(%{"w" => "200", "pad" => "10", "bg" => "0000ff", "fm" => "png"})
    assert {Image.width(out), Image.height(out)} == {200, 133}
  end

  test "a translucent bg keeps its alpha in a PNG, and a JPEG stays opaque" do
    params = %{"w" => "300", "h" => "300", "fit" => "fill", "bg" => "80ff0000"}

    png = render!(Map.put(params, "fm", "png"))
    assert Image.bands(png) == 4
    assert {:ok, [255, 0, 0, 128]} = Image.get_pixel(png, 1, 1)

    jpg = render!(Map.put(params, "fm", "jpg"))
    assert Image.bands(jpg) == 3
  end

  # task-f67613e8d778209e: sharpening sets an alpha band aside and puts it back.
  test "sharp on an image with alpha keeps the alpha" do
    png =
      render!(%{
        "w" => "300",
        "h" => "300",
        "fit" => "fill",
        "bg" => "80ff0000",
        "sharp" => "60",
        "fm" => "png"
      })

    assert Image.bands(png) == 4
    assert {:ok, [255, 0, 0, 128]} = Image.get_pixel(png, 1, 1)
  end
end
