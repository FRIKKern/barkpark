defmodule Barkpark.Media.OrientationSanityTest do
  @moduledoc """
  task-54a30eca3797a0e6: `or=90`/`or=270` on a sized image crops the turned
  image to a centred square of its shorter side, as Sanity's CDN does
  (measured on a 640x400 source: `w=200&or=90` is 125x125); without `w`/`h`
  the whole turned image is kept. And `invert` works on an image with alpha.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.Transform
  alias Elixir.Vix.Vips.Operation

  setup do
    if Vix.available?(), do: :ok, else: {:skip, "no libvips on this host"}
  end

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "orient-#{System.unique_integer([:positive])}.#{ext}")

  defp render!(params, bands \\ 3) do
    src = tmp("png")
    color = if bands == 4, do: [40, 120, 200, 200], else: [40, 120, 200]
    {:ok, img} = Image.new(640, 400, color: color)
    :ok = Operation.pngsave(img, src)
    {:ok, plan} = Transform.parse(Map.put(params, "fm", "png"))
    dest = tmp("png")
    assert :ok = Vix.transform(src, dest, plan, nil)
    {:ok, out} = Image.open(dest)
    out
  end

  defp size(img), do: {Image.width(img), Image.height(img)}

  test "a sized turn is a centred square; an unsized one keeps the whole image" do
    assert size(render!(%{"w" => "200", "or" => "90"})) == {125, 125}
    assert size(render!(%{"h" => "100", "or" => "270"})) == {100, 100}
    assert size(render!(%{"rect" => "0,0,320,200", "w" => "160", "or" => "270"})) == {100, 100}
    assert size(render!(%{"or" => "90"})) == {400, 640}
    assert size(render!(%{"w" => "200", "or" => "180"})) == {200, 125}

    assert Transform.canonical(plan!(%{"w" => "200", "or" => "90"})) =~ ";or=90sq"
    assert Transform.canonical(plan!(%{"or" => "90"})) =~ ~r/;or=90\z/
  end

  test "invert keeps an alpha band" do
    out = render!(%{"w" => "100", "invert" => "true"}, 4)
    assert Image.bands(out) == 4
    # 255 - [40, 120, 200], give or take the resampler; alpha untouched.
    assert {:ok, [r, g, b, 200]} = Image.get_pixel(out, 1, 1)
    assert abs(r - 215) <= 3 and abs(g - 135) <= 3 and abs(b - 55) <= 3
  end

  defp plan!(params) do
    {:ok, plan} = Transform.parse(params)
    plan
  end
end
