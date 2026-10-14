defmodule Barkpark.Media.ImageBackend.Vix do
  @moduledoc """
  libvips rendition backend (via the `:image` dep). Canonical on
  macOS/Linux/Docker. The pipeline — open, aspect-preserving thumbnail, optional
  centered text watermark, write at quality — is the original `Renditions` code,
  moved behind `Barkpark.Media.ImageBackend` unchanged.

  `Image.*` resolves at runtime; on a host without the `:image` dep (e.g. native
  Windows, where this backend is never selected) these calls are simply never
  reached.

  ## Resource-exhaustion posture (decompression bombs)

  Unlike the ImageMagick CLI backend — which fully decodes into RAM and so is
  bounded here by an explicit `-limit memory/map/time` plus an OTP deadline —
  libvips processes images as a demand-driven pipeline of small scanline
  regions, never materialising the full uncompressed raster. A pixel-count bomb
  therefore cannot pin RAM the way it can under ImageMagick, and every call runs
  in-process (no shell-out to bound). libvips also honours its own global caps
  (`VIPS_MAX_MEM`, `VIPS_DISC_THRESHOLD`) if set — so this backend is
  bomb-RESISTANT by streaming.

  On top of that streaming resistance we carry an explicit **pre-decode
  ceiling** for defense-in-depth — the twin of Magick's `-limit memory 256MiB`.
  The MECHANISM differs: libvips exposes no per-call memory limit, so this is an
  IN-PROCESS header guard (`guard_dimensions/1`), NOT a CLI `-limit`. `Image.open`
  reports the declared raster dimensions lazily from the header (~1ms even on a
  50000² bomb — it never decodes), and `Image.thumbnail` is ALSO lazy, so the
  guard cannot lean on a later stage failing: it inspects `width * height *
  bands` (estimated 8-bit decode bytes) between open and thumbnail and rejects up
  front with `{:error, :vix_dimensions_exceeded}` when that exceeds the ceiling.
  The ceiling mirrors Magick's 256MiB and is overridable per-env via
  `config :barkpark, Barkpark.Media.ImageBackend.Vix, max_decode_bytes: N`.
  """
  @behaviour Barkpark.Media.ImageBackend

  alias Barkpark.Media.Transform

  require Logger

  # The `:image` dep is OPTIONAL by construction (api/mix.exs image_dep/0):
  # absent on native Windows by default and under BARKPARK_SKIP_IMAGE=1 (the
  # mix-test CI lane, which never executes a vips-reaching test — they are
  # `:requires_vips`-tagged and default-excluded). `available?/0` is the
  # runtime guard: no `Image.*` call is reachable when the module is missing,
  # as the moduledoc records. Without this directive the compiler's
  # undefined-module warning turns `mix compile --warnings-as-errors` red on
  # every image-less host, which is exactly the supported configuration.
  @compile {:no_warn_undefined, [Image, Image.Text, Vix.Vips.Image, Vix.Vips.Operation]}

  # Explicit pre-decode raster ceiling, mirroring Magick's `-limit memory 256MiB`
  # so BOTH backends fail closed on the same class of decompression bomb. This is
  # the estimated fully-decoded size (one byte per 8-bit sample); libvips never
  # materialises it, but the guard rejects absurd declared dimensions before the
  # pipeline is built. Overridable per-env for tests via
  # `config :barkpark, __MODULE__, max_decode_bytes: N`.
  @default_max_decode_bytes 256 * 1024 * 1024

  @impl true
  def available?, do: Code.ensure_loaded?(Image)

  # A named preset is a fixed transform plan: `render/4` builds the plan and
  # runs it through `transform/4`, so presets and URL-parameter transforms share
  # one pipeline. Without `:crop` a preset is `fit=clip` inside its box (the
  # libvips `thumbnail` default this backend always used); with `:crop`
  # (`og`'s `:attention`) it is `fit=crop` with that smart-crop mode.
  @impl true
  def render(src, dest, spec, watermark) do
    transform(src, dest, preset_plan(spec), watermark)
  end

  @impl true
  def transform(src, dest, plan, watermark) do
    with {:ok, image} <- Image.open(src),
         :ok <- guard_dimensions(image),
         {src_w, src_h} = oriented_size(image),
         geometry = Transform.geometry(plan, src_w, src_h),
         {:ok, image} <- shape(src, geometry),
         {:ok, image} <- crop(image, geometry.crop),
         {:ok, image} <- pad(image, geometry.pad),
         {:ok, stamped} <- maybe_watermark(image, watermark) do
      write_image(stamped, dest, plan)
    end
  end

  @impl true
  def avif?, do: avif_supported?()

  @doc false
  def preset_plan(spec) do
    {fit, crop} =
      case Map.get(spec, :crop) do
        nil -> {"clip", []}
        mode -> {"crop", [to_string(mode)]}
      end

    %{
      w: spec.max_width,
      h: spec.max_height,
      fit: fit,
      crop: crop,
      rect: nil,
      fp: nil,
      fm: spec.format,
      auto_format: false,
      q: spec.quality
    }
  end

  # Width and height as the viewer sees them: EXIF orientations 5-8 swap the
  # axes, and every later step works on the auto-rotated image.
  defp oriented_size(image) do
    case Vix.Vips.Image.header_value(image, "orientation") do
      {:ok, o} when o in 5..8 -> {Image.height(image), Image.width(image)}
      _ -> {Image.width(image), Image.height(image)}
    end
  end

  # `shape/2` applies rect, resize and any smart crop; `crop/2` then cuts a
  # plain box. Without a rect, libvips `thumbnail` loads from the PATH, which
  # shrinks a JPEG while decoding it (much faster than decode-then-resize) and
  # auto-rotates. libvips' smart crop runs inside `thumbnail` too: a separate
  # `smartcrop` over a sequentially loaded JPEG fails with "out of order read".
  defp shape(src, %{rect: nil, crop: {:smart, mode, w, h}}),
    do: smart_thumbnail(src, mode, w, h)

  defp shape(src, %{rect: nil, resize: {w, h}}),
    do: Image.thumbnail(src, w, height: h, resize: :force)

  defp shape(src, %{rect: rect, resize: resize, crop: crop}) do
    with {:ok, image} <- Image.open(src, access: :random),
         {:ok, rotated} <- Image.autorotate(image) |> unwrap_rotate(),
         {:ok, cut} <- cut_rect(rotated, rect) do
      case {resize, crop} do
        {_, {:smart, mode, w, h}} -> smart_thumbnail(cut, mode, w, h)
        {nil, _} -> {:ok, cut}
        {{rw, rh}, _} -> Image.thumbnail(cut, rw, height: rh, resize: :force)
      end
    end
  end

  defp cut_rect(image, nil), do: {:ok, image}
  defp cut_rect(image, {x, y, w, h}), do: Image.crop(image, x, y, w, h)

  defp smart_thumbnail(src_or_image, mode, w, h) do
    crop = if mode == "entropy", do: :entropy, else: :attention
    Image.thumbnail(src_or_image, w, height: h, crop: crop)
  end

  defp unwrap_rotate({:ok, {image, _flags}}), do: {:ok, image}
  # A struct pattern would require the optional Vix module at compile time.
  # Keep the same runtime type check on hosts that do not carry that dependency.
  defp unwrap_rotate({:ok, image}) when is_struct(image, Vix.Vips.Image), do: {:ok, image}
  defp unwrap_rotate(error), do: error

  defp crop(image, nil), do: {:ok, image}
  defp crop(image, {:smart, _mode, _w, _h}), do: {:ok, image}

  defp crop(image, {left, top, w, h}) do
    Image.crop(
      image,
      left,
      top,
      min(w, Image.width(image) - left),
      min(h, Image.height(image) - top)
    )
  end

  defp pad(image, nil), do: {:ok, image}

  defp pad(image, {w, h}) do
    x = div(max(w - Image.width(image), 0), 2)
    y = div(max(h - Image.height(image), 0), 2)
    background = List.duplicate(255, Image.bands(image))

    Vix.Vips.Operation.embed(image, x, y, w, h,
      extend: :VIPS_EXTEND_BACKGROUND,
      background: background
    )
  end

  # Reject a decompression bomb BEFORE the (lazy) thumbnail pipeline is built.
  # `Image.{width,height,bands}` read the already-parsed header (no decode), so
  # this is cheap even on a 50000² input. The atom-tagged error tuple flows
  # untouched through `Renditions.generate/6` (which matches `{:error, reason}`).
  defp guard_dimensions(image) do
    estimated_bytes = Image.width(image) * Image.height(image) * Image.bands(image)

    if estimated_bytes > max_decode_bytes() do
      {:error, :vix_dimensions_exceeded}
    else
      :ok
    end
  end

  defp max_decode_bytes,
    do: Keyword.get(config(), :max_decode_bytes, @default_max_decode_bytes)

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])

  defp maybe_watermark(image, profile) when profile in [nil, "", "none"], do: {:ok, image}

  defp maybe_watermark(image, profile) when profile in ["draft", "editorial"] do
    label = watermark_label(profile)

    # `Image.Text.text/2` takes no RGBA fill and no `background_color` option:
    # both answered `{:error, "Invalid option ..."}`, so every watermarked
    # transform and rendition failed and answered 404 (task-c9fb2c2087dbba4d).
    # White text on the default transparent background, with its alpha band
    # scaled to 35%, gives the same translucent label.
    with {:ok, text_layer} <-
           Image.Text.text(label,
             font_size: watermark_font_size(image),
             text_fill_color: :white
           ),
         {text, alpha} = Image.split_alpha(text_layer),
         {:ok, faded_alpha} <- Image.Math.multiply(alpha, 0.35),
         {:ok, text_layer} <- Image.add_alpha(text, faded_alpha),
         {:ok, watermarked} <- Image.compose(image, text_layer, x: :center, y: :middle) do
      {:ok, watermarked}
    else
      {:error, _} = error -> error
      _ -> {:ok, image}
    end
  end

  defp maybe_watermark(image, _profile), do: {:ok, image}

  defp watermark_label("draft"), do: "DRAFT"
  defp watermark_label("editorial"), do: "EDITORIAL USE ONLY"
  defp watermark_label(_), do: "DRAFT"

  defp watermark_font_size(image) do
    min(Image.width(image), Image.height(image))
    |> div(12)
    |> max(18)
  end

  # `fm` picks the encoder; the caller already gave `dest` the matching
  # extension. Every output drops EXIF and other metadata (`strip`), which also
  # keeps camera GPS tags off public derivatives.
  defp write_image(image, dest, plan) do
    case Image.write(image, dest, write_options(plan.fm, plan.q)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  The `Image.write/3` options for a format and URL `q`.

  AVIF sets its effort and quality explicitly. Left to libvips, heifsave runs
  at effort 4 with `q` passed 1:1 to the AV1 quantizer: on a 2-core ARM box
  that took 15 to 43 s per 1200 px image, and the files came out larger than
  WebP at the same `q`. `Transform.avif_effort/0` (default 1) and
  `Transform.avif_quality/1` set both. `Image` takes effort as 1 to 10 and
  passes `effort - 1` to libvips, hence the `+ 1`.
  """
  @spec write_options(String.t(), pos_integer()) :: keyword()
  def write_options("png", _q), do: [suffix: ".png", strip_metadata: true]
  def write_options("webp", q), do: [suffix: ".webp", quality: q, strip_metadata: true]

  def write_options("avif", q) do
    [
      suffix: ".avif",
      quality: Transform.avif_quality(q),
      effort: Transform.avif_effort() + 1,
      strip_metadata: true
    ]
  end

  def write_options(_jpg, q), do: [suffix: ".jpg", quality: q, strip_metadata: true]

  @doc """
  AVIF encode time on this node in milliseconds per output megapixel, or nil
  when this node cannot encode AVIF.

  `config :barkpark, #{inspect(__MODULE__)}, avif_ms_per_megapixel: N` sets it.
  Otherwise the first call encodes a 512 x 512 test image of blurred noise
  over gradients twice with the AVIF write options, keeps the faster run and
  caches the result for the life of the node. Noise is slower to encode than
  most photos, so the estimate leans towards WebP.
  """
  @impl true
  @spec avif_ms_per_megapixel() :: number() | nil
  def avif_ms_per_megapixel do
    case Keyword.get(config(), :avif_ms_per_megapixel) do
      n when is_number(n) and n > 0 -> n
      _ -> measured_avif_cost()
    end
  end

  defp measured_avif_cost do
    case :persistent_term.get({__MODULE__, :avif_ms_per_mp}, :unknown) do
      :unknown ->
        cost = if avif_supported?(), do: probe_avif_cost(), else: nil
        :persistent_term.put({__MODULE__, :avif_ms_per_mp}, cost)
        cost

      cached ->
        cached
    end
  end

  @probe_side 512

  defp probe_avif_cost do
    alias Vix.Vips.Operation, as: Op
    n = @probe_side

    with {:ok, noise} <- Op.gaussnoise(n, n, sigma: 48.0, mean: 128.0),
         {:ok, noise} <- Op.gaussblur(noise, 1.2),
         {:ok, xyz} <- Op.xyz(n, n),
         {:ok, x} <- Op.extract_band(xyz, 0),
         {:ok, y} <- Op.extract_band(xyz, 1),
         {:ok, r} <- Op.linear(x, [255.0 / n], [0.0]),
         {:ok, b} <- Op.linear(y, [255.0 / n], [0.0]),
         {:ok, r} <- Op.add(r, noise),
         {:ok, b} <- Op.add(b, noise),
         {:ok, rgb} <- Op.bandjoin([r, noise, b]),
         {:ok, rgb} <- Op.cast(rgb, :VIPS_FORMAT_UCHAR),
         {:ok, rgb} <- Vix.Vips.Image.copy_memory(rgb) do
      opts = write_options("avif", 75)

      ms =
        for _ <- 1..2 do
          {us, {:ok, _}} = :timer.tc(fn -> Image.write(rgb, :memory, opts) end)
          us / 1000
        end
        |> Enum.min()

      cost = Float.round(ms / (n * n / 1_000_000), 1)
      Logger.info("Barkpark.Media.ImageBackend.Vix: AVIF encode cost #{cost} ms per megapixel")
      cost
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # AVIF needs libvips built with libheif and an AV1 encoder. The precompiled
  # libvips that ships with vix may lack one; probe once per node and cache.
  defp avif_supported? do
    case :persistent_term.get({__MODULE__, :avif?}, :unknown) do
      :unknown ->
        supported =
          try do
            {:ok, img} = Image.new(2, 2)
            match?({:ok, _}, Image.write(img, :memory, suffix: ".avif"))
          rescue
            _ -> false
          end

        :persistent_term.put({__MODULE__, :avif?}, supported)
        supported

      cached ->
        cached
    end
  end
end
