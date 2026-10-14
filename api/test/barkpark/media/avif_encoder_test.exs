defmodule Barkpark.Media.AvifEncoderTest do
  @moduledoc """
  task-a99abd94ae4c2381: AVIF is encoded with an explicit effort and a mapped
  quality, and the cache key follows the encoder settings.

  The `write_options/2` checks need no libvips: they read the keyword list the
  backend hands to `Image.write/3`. The encode checks run when the `:image`
  dep and an AVIF encoder are present.
  """
  # async: false: these tests set `:barkpark, Barkpark.Media.Transform` and
  # `:barkpark, Barkpark.Media.ImageBackend.Vix`, which are node-global.
  use ExUnit.Case, async: false

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.Transform
  alias Elixir.Vix.Vips.Operation, as: Op

  setup do
    transform_env = Application.get_env(:barkpark, Transform)
    vix_env = Application.get_env(:barkpark, Vix)

    on_exit(fn ->
      restore(Transform, transform_env)
      restore(Vix, vix_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp put_env(key, kw),
    do:
      Application.put_env(
        :barkpark,
        key,
        Keyword.merge(Application.get_env(:barkpark, key, []), kw)
      )

  defp plan!(params) do
    {:ok, plan} = Transform.parse(params)
    plan
  end

  describe "write_options/2" do
    test "AVIF passes an explicit effort and the mapped quality" do
      opts = Vix.write_options("avif", 75)
      assert opts[:suffix] == ".avif"
      assert opts[:quality] == Transform.avif_quality(75)
      assert opts[:quality] == 55
      # `Image` takes effort 1..10 and passes effort - 1 to libvips: 2 is libvips effort 1.
      assert opts[:effort] == 2
      assert opts[:strip_metadata] == true
    end

    test "the configured effort reaches the encoder" do
      put_env(Transform, avif_effort: 3)
      assert Vix.write_options("avif", 75)[:effort] == 4
    end

    test "JPEG and WebP keep q as given and set no effort" do
      assert Vix.write_options("jpg", 85) == [suffix: ".jpg", quality: 85, strip_metadata: true]
      assert Vix.write_options("webp", 85) == [suffix: ".webp", quality: 85, strip_metadata: true]
    end
  end

  describe "cache key" do
    test "a changed AVIF effort is a new cache file" do
      plan = plan!(%{"w" => "640", "fm" => "avif"})
      before = Transform.cache_name(plan)
      put_env(Transform, avif_effort: 4)
      refute Transform.cache_name(plan) == before
    end

    test "a changed AVIF effort leaves WebP and JPEG keys alone" do
      webp = plan!(%{"w" => "640", "fm" => "webp"})
      jpg = plan!(%{"w" => "640", "fm" => "jpg"})
      {w0, j0} = {Transform.cache_name(webp), Transform.cache_name(jpg)}
      put_env(Transform, avif_effort: 4)
      assert {Transform.cache_name(webp), Transform.cache_name(jpg)} == {w0, j0}
    end
  end

  describe "AVIF cost" do
    test "a configured cost is used as is" do
      put_env(Vix, avif_ms_per_megapixel: 250)
      assert Vix.avif_ms_per_megapixel() == 250
    end

    test "a configured budget changes the auto=format choice" do
      plan = plan!(%{"w" => "1200", "auto" => "format"})
      opts = [accept: "image/avif,image/webp", avif?: true, source_size: {2151, 2214}]

      assert Transform.resolve(plan, opts ++ [avif_ms_per_megapixel: 2000]).fm == "webp"
      put_env(Transform, avif_budget_ms: 4000)
      assert Transform.resolve(plan, opts ++ [avif_ms_per_megapixel: 2000]).fm == "avif"
    end
  end

  describe "encode" do
    setup do
      if Vix.available?() and Vix.avif?(),
        do: :ok,
        else: {:skip, "no libvips AVIF encoder on this host"}
    end

    test "the measured cost is a positive number" do
      cost = Vix.avif_ms_per_megapixel()
      assert is_number(cost) and cost > 0
    end

    test "transform/4 writes an AVIF no larger than the WebP at the same q" do
      src = Path.join(System.tmp_dir!(), "avif-src-#{System.unique_integer([:positive])}.jpg")
      {:ok, noise} = Op.gaussnoise(800, 600, sigma: 40.0, mean: 128.0)
      {:ok, noise} = Op.gaussblur(noise, 2.0)
      {:ok, rgb} = Op.bandjoin([noise, noise, noise])
      {:ok, rgb} = Op.cast(rgb, :VIPS_FORMAT_UCHAR)
      {:ok, _} = Image.write(rgb, src, quality: 90)

      sizes =
        for fm <- ~w(avif webp), into: %{} do
          dest =
            Path.join(System.tmp_dir!(), "avif-out-#{System.unique_integer([:positive])}.#{fm}")

          assert :ok =
                   Vix.transform(src, dest, plan!(%{"w" => "400", "fm" => fm, "q" => "75"}), nil)

          {fm, File.stat!(dest).size}
        end

      assert sizes["avif"] <= sizes["webp"]
    end
  end
end
