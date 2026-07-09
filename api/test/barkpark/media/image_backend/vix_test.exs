defmodule Barkpark.Media.ImageBackend.VixTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix

  # All tests in this module require libvips / the :image dep to be present.
  # On hosts without it, we skip rather than fail.
  setup_all do
    if Vix.available?() do
      :ok
    else
      {:skip, "libvips / :image not available on this host"}
    end
  end

  # ---------------------------------------------------------------------------
  # available?/0
  # ---------------------------------------------------------------------------

  test "available?/0 returns true when the Image module is loaded" do
    # On macOS/Linux CI the :image dep is always compiled — this must be true.
    assert Vix.available?() == true
  end

  # ---------------------------------------------------------------------------
  # render/4 — happy paths
  # ---------------------------------------------------------------------------

  test "render/4 produces a JPEG when format is jpg and watermark is nil" do
    src = write_tmp_jpeg(200, 150)
    dest = tmp_path("out_jpg.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    assert :ok = Vix.render(src, dest, spec, nil)
    assert File.exists?(dest)
  end

  test "render/4 produces a WebP when format is webp" do
    src = write_tmp_jpeg(300, 200)
    dest = tmp_path("out_webp.webp")
    spec = %{max_width: 150, max_height: 150, quality: 75, format: "webp"}

    assert :ok = Vix.render(src, dest, spec, nil)
    assert File.exists?(dest)
  end

  test "render/4 passes through when watermark is the string none" do
    src = write_tmp_jpeg(200, 200)
    dest = tmp_path("out_none.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    assert :ok = Vix.render(src, dest, spec, "none")
    assert File.exists?(dest)
  end

  test "render/4 passes through for an unknown watermark profile" do
    src = write_tmp_jpeg(200, 200)
    dest = tmp_path("out_unknown.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    # Unrecognised profiles hit the catch-all maybe_watermark clause → passthrough.
    assert :ok = Vix.render(src, dest, spec, "confidential")
    assert File.exists?(dest)
  end

  # ---------------------------------------------------------------------------
  # render/4 — exact-crop (:crop) vs fit (A4 — the og share-card geometry)
  # ---------------------------------------------------------------------------

  # The og share-card preset is an EXACT crop, not an aspect-preserving fit.
  # These prove the `:crop` option threads through the real libvips backend so a
  # portrait source is upscaled-and-cropped to a constant 1200×630 card (the
  # only geometry the preview manifest can safely hardcode).

  @og_spec %{max_width: 1200, max_height: 630, format: "jpg", quality: 85}

  test "a portrait source with crop: :attention yields EXACTLY 1200x630" do
    src = write_tmp_png(400, 800)
    dest = tmp_path("og_crop.jpg")

    assert :ok = Vix.render(src, dest, Map.put(@og_spec, :crop, :attention), nil)

    {:ok, out} = Image.open(dest)
    assert {Image.width(out), Image.height(out)} == {1200, 630}
  end

  test "the SAME portrait source WITHOUT crop fits aspect-preserving (not 1200x630)" do
    src = write_tmp_png(400, 800)
    dest = tmp_path("og_fit.jpg")

    assert :ok = Vix.render(src, dest, @og_spec, nil)

    {:ok, out} = Image.open(dest)
    # A 400×800 portrait fit into a 1200×630 box is height-bound → 315×630.
    assert {Image.width(out), Image.height(out)} == {315, 630}
  end

  # ---------------------------------------------------------------------------
  # render/4 — error path
  # ---------------------------------------------------------------------------

  test "render/4 returns an error tuple when the source file does not exist" do
    dest = tmp_path("out_err.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    assert {:error, _reason} = Vix.render("/nonexistent/path/image.jpg", dest, spec, nil)
    refute File.exists?(dest)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_tmp_jpeg(width, height) do
    path = tmp_path("src_#{width}x#{height}_#{System.unique_integer([:positive])}.jpg")
    img = Image.new!(width, height, color: [120, 160, 200])
    {:ok, _} = Image.write(img, path, suffix: ".jpg", quality: 90)
    path
  end

  defp write_tmp_png(width, height) do
    path = tmp_path("src_#{width}x#{height}_#{System.unique_integer([:positive])}.png")
    img = Image.new!(width, height, color: [30, 82, 67])
    {:ok, _} = Image.write(img, path, suffix: ".png")
    path
  end

  defp tmp_path(name) do
    dir = System.tmp_dir!()
    unique = System.unique_integer([:positive])
    Path.join(dir, "vix_test_#{unique}_#{name}")
  end
end
