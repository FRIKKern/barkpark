defmodule Barkpark.Media.ImageBackend.VixTest do
  # async: false — this module swaps node-global env
  # (`:barkpark, Barkpark.Media.ImageBackend.Vix`) to force a decode-budget
  # rejection. Application env is ONE value for the whole node — the SQL sandbox
  # isolates the DB connection, never the VM-global env (see
  # api/test/barkpark/application_env_isolation_test.exs, which proves the leak
  # channel). Ratchet: scripts/async_env_seam_scan.exs.
  use ExUnit.Case, async: false

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
  # render/4 — decompression-bomb ceiling (defense-in-depth, twin of Magick)
  # ---------------------------------------------------------------------------

  # A ~73-byte PNG whose IHDR declares 50000×50000 RGB (≈7.5 GB decoded) over a
  # 16-byte bogus IDAT. libvips `Image.open` reads the header lazily and reports
  # the declared dimensions WITHOUT decoding (and `Image.thumbnail` is also lazy),
  # so on origin/main render/4 proceeds past the guard-less open into thumbnail
  # instead of rejecting. The pre-decode guard rejects it up front.
  @png_bomb Path.join([
              __DIR__,
              "..",
              "..",
              "..",
              "support",
              "fixtures",
              "media",
              "png_bomb_50000x50000.png"
            ])

  test "render/4 rejects a pixel-dimension bomb before decoding (fail-before)" do
    # Sanity: the fixture really does open and report the bomb dimensions —
    # proving the guard, not a decode failure, is what stops the render.
    {:ok, bomb} = Image.open(@png_bomb)
    assert {Image.width(bomb), Image.height(bomb)} == {50000, 50000}

    dest = tmp_path("bomb_out.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    assert {:error, :vix_dimensions_exceeded} = Vix.render(@png_bomb, dest, spec, nil)
    refute File.exists?(dest)
  end

  test "render/4 max_decode_bytes ceiling is config-overridable" do
    # Raise the ceiling above the bomb's estimated raster and the guard lets it
    # through to the (still lazy) thumbnail — proving the cap is the gate, and it
    # is env-tunable exactly like Magick's -limit. Restore afterwards.
    key = Barkpark.Media.ImageBackend.Vix
    prev = Application.get_env(:barkpark, key)
    on_exit(fn -> restore_env(key, prev) end)

    Application.put_env(:barkpark, key, max_decode_bytes: 50_000 * 50_000 * 3 + 1)

    dest = tmp_path("bomb_uncapped.jpg")
    spec = %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

    # Past the guard now; the bogus IDAT means the lazy decode ultimately fails,
    # so we assert only that the failure is NOT the dimension guard.
    assert Vix.render(@png_bomb, dest, spec, nil) != {:error, :vix_dimensions_exceeded}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp restore_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_env(key, prev), do: Application.put_env(:barkpark, key, prev)

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
