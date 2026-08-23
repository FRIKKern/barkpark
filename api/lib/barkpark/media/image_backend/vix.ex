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

  # The `:image` dep is OPTIONAL by construction (api/mix.exs image_dep/0):
  # absent on native Windows by default and under BARKPARK_SKIP_IMAGE=1 (the
  # mix-test CI lane, which never executes a vips-reaching test — they are
  # `:requires_vips`-tagged and default-excluded). `available?/0` is the
  # runtime guard: no `Image.*` call is reachable when the module is missing,
  # as the moduledoc records. Without this directive the compiler's
  # undefined-module warning turns `mix compile --warnings-as-errors` red on
  # every image-less host, which is exactly the supported configuration.
  @compile {:no_warn_undefined, [Image, Image.Text]}

  # Explicit pre-decode raster ceiling, mirroring Magick's `-limit memory 256MiB`
  # so BOTH backends fail closed on the same class of decompression bomb. This is
  # the estimated fully-decoded size (one byte per 8-bit sample); libvips never
  # materialises it, but the guard rejects absurd declared dimensions before the
  # pipeline is built. Overridable per-env for tests via
  # `config :barkpark, __MODULE__, max_decode_bytes: N`.
  @default_max_decode_bytes 256 * 1024 * 1024

  @impl true
  def available?, do: Code.ensure_loaded?(Image)

  @impl true
  def render(src, dest, spec, watermark) do
    with {:ok, image} <- Image.open(src),
         :ok <- guard_dimensions(image),
         {:ok, thumb} <- Image.thumbnail(image, spec.max_width, thumbnail_opts(spec)),
         {:ok, stamped} <- maybe_watermark(thumb, watermark),
         :ok <- write_image(stamped, dest, spec) do
      :ok
    end
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

  # Aspect-preserving fit by default; an exact-fill crop when the spec asks for
  # one (`crop: :attention` → cover-and-centre-crop to exactly WxH). `Image 0.67`
  # `thumbnail/3` takes `:crop` alongside `:height`.
  defp thumbnail_opts(%{crop: crop} = spec) when not is_nil(crop),
    do: [height: spec.max_height, crop: crop]

  defp thumbnail_opts(spec), do: [height: spec.max_height]

  defp maybe_watermark(image, profile) when profile in [nil, "", "none"], do: {:ok, image}

  defp maybe_watermark(image, profile) when profile in ["draft", "editorial"] do
    label = watermark_label(profile)

    with {:ok, text_layer} <-
           Image.Text.text(label,
             font_size: watermark_font_size(image),
             text_fill_color: {255, 255, 255, 0.35},
             background_color: :none
           ),
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

  defp write_image(image, dest, %{format: "webp"} = spec) do
    case Image.write(image, dest, suffix: ".webp", quality: spec.quality) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_image(image, dest, spec) do
    case Image.write(image, dest, suffix: ".jpg", quality: spec.quality) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
