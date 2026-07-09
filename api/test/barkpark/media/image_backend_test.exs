defmodule Barkpark.Media.ImageBackendTest do
  # async: false — toggles global :image_backend Application env, same race
  # concern as cdn_test.exs.
  use ExUnit.Case, async: false

  alias Barkpark.Media.ImageBackend

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

  test "impl/0 returns configured override module when set" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Magick
  end

  test "impl/0 returns Vix as default on non-Windows" do
    Application.delete_env(:barkpark, :image_backend)
    # This test runs on macOS/Linux CI — the OS default must be Vix.
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Vix
  end

  test "impl/0 returns the last-set override, not an earlier one" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Vix)
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Magick
  end

  test "impl/0 falls back to OS default when config is deleted after being set" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    Application.delete_env(:barkpark, :image_backend)
    # On non-Windows this must revert to Vix
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Vix
  end

  # The og share-card preset is an EXACT crop, not an aspect-preserving fit. This
  # proves the `:crop` option threads through the real libvips backend so a
  # portrait source is upscaled-and-cropped to a constant 1200×630 card (the only
  # geometry the preview manifest can safely hardcode). Runs only where libvips
  # (the :image dep) is loaded — the CI Elixir Test gate, macOS/Linux dev.
  describe "Vix.render/4 exact-crop (:crop) vs fit" do
    @og_spec %{max_width: 1200, max_height: 630, format: "jpg", quality: 85}

    test "a portrait source with crop: :attention yields EXACTLY 1200x630" do
      # libvips-only proof; the Magick backend covers crop on native Windows.
      if Code.ensure_loaded?(Image) do
        src = write_portrait_png()
        dest = tmp_path("og-crop", "jpg")

        assert :ok =
                 Barkpark.Media.ImageBackend.Vix.render(
                   src,
                   dest,
                   Map.put(@og_spec, :crop, :attention),
                   nil
                 )

        {:ok, out} = Image.open(dest)
        assert {Image.width(out), Image.height(out)} == {1200, 630}
      end
    end

    test "the SAME portrait source WITHOUT crop fits aspect-preserving (not 1200x630)" do
      if Code.ensure_loaded?(Image) do
        src = write_portrait_png()
        dest = tmp_path("og-fit", "jpg")

        assert :ok = Barkpark.Media.ImageBackend.Vix.render(src, dest, @og_spec, nil)

        {:ok, out} = Image.open(dest)
        # A 400×800 portrait fit into a 1200×630 box is height-bound → 315×630.
        assert {Image.width(out), Image.height(out)} == {315, 630}
      end
    end

    defp write_portrait_png do
      {:ok, img} = Image.new(400, 800, color: [30, 82, 67])
      path = tmp_path("portrait", "png")
      {:ok, _} = Image.write(img, path, suffix: ".png")
      path
    end

    defp tmp_path(prefix, ext) do
      path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.#{ext}")
      on_exit(fn -> File.rm(path) end)
      path
    end
  end
end
