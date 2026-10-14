defmodule Barkpark.Media.Transform do
  @moduledoc """
  On-demand image transforms from URL parameters.

  An image upload stores the original once. Any size, crop or format is made on
  the first request from URL parameters and cached on disk, the way Sanity's
  image pipeline and `next/image` work. The URL contract lives in
  `docs/media/IMAGE-TRANSFORMS.md`.

  This module is pure. It parses and normalises the parameters into a `plan`,
  derives the cache key from the normalised plan, and computes the geometry
  (rect, resize, crop, pad) for a given source size. The backend
  (`Barkpark.Media.ImageBackend.Vix.transform/4`) only executes the geometry.
  Keeping the arithmetic here lets the CI lane test it without libvips.

  ## Limits

    * `w` and `h` are clamped to `max_dimension` (default 4096).
    * `w` and `h` above 100 px are rounded UP to a multiple of
      `dimension_step` (default 10), so `w=1199` and `w=1200` share one cached
      file. Values of 100 px and below stay exact.
    * `q` is rounded to the nearest multiple of 5.
    * Each asset keeps at most `max_variants_per_asset` (default 100) cached
      parameter sets; `Barkpark.Media.Renditions.transform/3` refuses a new set
      past that.

  All three are read from `config :barkpark, Barkpark.Media.Transform`.

  ## AVIF

  AVIF is encoded at libvips effort `avif_effort` (default 1 of 0 to 9; AV1
  speed 8, imgproxy's default). The URL's `q` goes through `avif_quality/1`,
  so an AVIF at a given `q` is no larger than a WebP at the same `q`.

  `auto=format` picks AVIF only when the estimated encode time fits
  `avif_budget_ms` (default 1500): output megapixels times the backend's
  measured AVIF cost on this node (`ImageBackend.avif_ms_per_megapixel/0`).
  Past the budget it picks WebP. `fm=avif` always encodes AVIF.

  The cache key of an AVIF carries the encoder settings (`encoder_tag/1`), so a
  change to them renders new files instead of serving old bytes. JPEG, PNG and
  WebP keys do not change.
  """

  @fits ~w(clip crop fill max min)
  @crop_modes ~w(center focalpoint entropy attention top bottom left right)
  @formats ~w(jpg png webp avif)
  @default_quality 75

  # AVIF quality for each URL `q` bucket. Measured on photos, a book cover, a
  # screenshot and a flat graphic at 256 to 1200 px with libvips 8.17 at effort
  # 1: each value is the highest AVIF quality whose file was no larger than the
  # WebP at that `q` for every sample, minus 2, then made non-decreasing. A
  # change here must bump `@avif_qmap_version` so cached AVIFs are re-rendered.
  @avif_qmap %{
    5 => 4,
    10 => 9,
    15 => 14,
    20 => 17,
    25 => 22,
    30 => 25,
    35 => 28,
    40 => 33,
    45 => 38,
    50 => 41,
    55 => 41,
    60 => 44,
    65 => 48,
    70 => 54,
    75 => 55,
    80 => 62,
    85 => 71,
    90 => 79,
    95 => 87,
    100 => 87
  }
  @avif_qmap_version 1
  @default_avif_effort 1
  @default_avif_budget_ms 1500

  # Parameters this module owns. Anything else on the URL (signed-URL `_`/`exp`,
  # CDN cache-busters) passes through untouched.
  @params ~w(w h fit crop rect fp-x fp-y fm q auto)

  # Transform vocabulary Sanity and imgix accept that Barkpark does not apply.
  # A request carrying one is refused (400) rather than silently ignored.
  @unsupported ~w(dpr blur sharp flip or quality bg invert sat pad)

  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @type plan :: %{
          w: pos_integer() | nil,
          h: pos_integer() | nil,
          fit: String.t(),
          crop: [String.t()],
          rect: rect() | nil,
          fp: {float(), float()} | nil,
          fm: String.t() | nil,
          auto_format: boolean(),
          q: pos_integer()
        }

  @doc "Parameter names this module reads from a query string."
  @spec param_names() :: [String.t()]
  def param_names, do: @params

  @doc "True when `params` carries at least one transform parameter."
  @spec requested?(map()) :: boolean()
  def requested?(params) when is_map(params), do: Enum.any?(@params, &Map.has_key?(params, &1))

  @doc "Transform parameters on the request that Barkpark does not support."
  @spec unsupported(map()) :: [String.t()]
  def unsupported(params) when is_map(params),
    do: Enum.filter(@unsupported, &Map.has_key?(params, &1))

  @doc """
  Parse query parameters into a normalised plan.

  Returns `{:error, {:invalid_param, name, message}}` for a value that does not
  parse. Out-of-range sizes are clamped, not refused.
  """
  @spec parse(map()) :: {:ok, plan()} | {:error, {:invalid_param, String.t(), String.t()}}
  def parse(params) when is_map(params) do
    with {:ok, w} <- dimension(params, "w"),
         {:ok, h} <- dimension(params, "h"),
         {:ok, fit} <- enum(params, "fit", @fits, "clip"),
         {:ok, crop} <- crop_modes(params),
         {:ok, rect} <- rect(params),
         {:ok, fp} <- focal_point(params),
         {:ok, fm} <- format(params),
         {:ok, auto_format} <- auto(params),
         {:ok, q} <- quality(params) do
      crop = if fp && crop == [], do: ["focalpoint"], else: crop

      {:ok,
       %{
         w: w,
         h: h,
         fit: fit,
         crop: crop,
         rect: rect,
         fp: fp,
         fm: fm,
         auto_format: auto_format,
         q: q
       }}
    end
  end

  @doc """
  Fill in the defaults that depend on the asset and the request.

    * `:focal_point` — the asset's stored focal point `{x, y}` (fractions of the
      original). Applied only when the plan crops, names no crop mode and has
      no `fp-x`/`fp-y` of its own. When the plan has a `rect`, the point is
      moved into the rect's coordinates.
    * `:source_size` — `{width, height}` of the original, needed to move a
      stored focal point into a rect. Without it a stored point is skipped when
      a rect is set.
    * `:accept` — the request's `Accept` header, read only for `auto=format`.
    * `:source_mime` — the original's mime type, used for the default format.
    * `:avif?` — whether the backend can encode AVIF.
    * `:avif_ms_per_megapixel` — the backend's AVIF encode cost, a number or a
      zero-arity function that returns one (called only when `auto=format`
      could pick AVIF). With a cost, `auto=format` picks AVIF only when the
      estimated encode time fits `avif_budget_ms/0`. Without one, no budget
      applies.
  """
  @spec resolve(plan(), keyword()) :: plan()
  def resolve(plan, opts \\ []) do
    plan
    |> resolve_focal(Keyword.get(opts, :focal_point), Keyword.get(opts, :source_size))
    |> resolve_format(Keyword.get(opts, :accept), Keyword.get(opts, :source_mime), %{
      avif?: Keyword.get(opts, :avif?, false),
      cost: Keyword.get(opts, :avif_ms_per_megapixel),
      source_size: Keyword.get(opts, :source_size)
    })
  end

  @doc """
  The normalised parameter string a cache entry is keyed on. Two URLs that mean
  the same transform produce the same string, whatever their parameter order.
  """
  @spec canonical(plan(), String.t() | nil) :: String.t()
  def canonical(plan, watermark \\ nil) do
    [
      "v1",
      "w=#{plan.w || "-"}",
      "h=#{plan.h || "-"}",
      "fit=#{plan.fit}",
      "crop=#{Enum.join(plan.crop, ",")}",
      "rect=#{format_rect(plan.rect)}",
      "fp=#{format_fp(plan.fp)}",
      "fm=#{plan.fm}",
      "q=#{plan.q}",
      "wm=#{watermark || "none"}"
    ]
    |> then(fn parts ->
      case encoder_tag(plan) do
        nil -> parts
        tag -> parts ++ ["enc=#{tag}"]
      end
    end)
    |> Enum.join(";")
  end

  @doc """
  The encoder settings that change an output's bytes beyond the plan, for the
  cache key. Only AVIF has one today; nil keeps the other formats' keys as
  they were, so their cached files keep serving.
  """
  @spec encoder_tag(plan()) :: String.t() | nil
  def encoder_tag(%{fm: "avif"}), do: "avif-e#{avif_effort()}-qm#{@avif_qmap_version}"
  def encoder_tag(_plan), do: nil

  @doc "AVIF encoder quality for a URL `q` (1 to 100)."
  @spec avif_quality(pos_integer()) :: pos_integer()
  def avif_quality(q) when is_integer(q) do
    bucket = (round(q / 5) * 5) |> max(5) |> min(100)
    Map.fetch!(@avif_qmap, bucket)
  end

  @doc "libvips AVIF effort, 0 (fastest) to 9 (slowest)."
  @spec avif_effort() :: 0..9
  def avif_effort, do: Keyword.get(config(), :avif_effort, @default_avif_effort)

  @doc "Most milliseconds `auto=format` lets an AVIF encode take before it picks WebP."
  @spec avif_budget_ms() :: pos_integer()
  def avif_budget_ms, do: Keyword.get(config(), :avif_budget_ms, @default_avif_budget_ms)

  @doc """
  Output pixel count for a plan. With the source size this is exact. Without
  it, `w` x `h`, or the one given side squared; nil when the plan names
  neither.
  """
  @spec output_pixels(plan(), {pos_integer(), pos_integer()} | nil) :: pos_integer() | nil
  def output_pixels(plan, {sw, sh}) when sw > 0 and sh > 0 do
    g = geometry(plan, sw, sh)

    {w, h} =
      cond do
        g.pad -> g.pad
        g.crop -> {elem(g.crop, 2), elem(g.crop, 3)}
        g.resize -> g.resize
        g.rect -> {elem(g.rect, 2), elem(g.rect, 3)}
        true -> {sw, sh}
      end

    w * h
  end

  def output_pixels(%{w: w, h: h}, _size) when is_integer(w) and is_integer(h), do: w * h
  def output_pixels(%{w: w}, _size) when is_integer(w), do: w * w
  def output_pixels(%{h: h}, _size) when is_integer(h), do: h * h
  def output_pixels(_plan, _size), do: nil

  @doc "Cache file name (hash + extension) for a resolved plan."
  @spec cache_name(plan(), String.t() | nil) :: String.t()
  def cache_name(plan, watermark \\ nil) do
    hash =
      :crypto.hash(:sha256, canonical(plan, watermark))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "#{hash}.#{plan.fm}"
  end

  @doc "MIME type for an output format."
  @spec mime(String.t()) :: String.t()
  def mime("jpg"), do: "image/jpeg"
  def mime("png"), do: "image/png"
  def mime("webp"), do: "image/webp"
  def mime("avif"), do: "image/avif"

  @doc """
  Geometry for a source of `src_w` x `src_h` pixels, in the order the backend
  applies it:

    * `:rect` — `{left, top, width, height}` cut from the source first, or nil;
    * `:resize` — `{width, height}` the (rect-cut) image is scaled to, or nil;
    * `:crop` — `{left, top, width, height}` cut from the resized image, or
      `{:smart, mode, width, height}` for libvips' `entropy`/`attention`, or nil;
    * `:pad` — `{width, height}` canvas the image is centred on (`fit=fill`), or nil.
  """
  @spec geometry(plan(), pos_integer(), pos_integer()) :: map()
  def geometry(plan, src_w, src_h) when src_w > 0 and src_h > 0 do
    rect = clamp_rect(plan.rect, src_w, src_h)

    {sw, sh} =
      case rect do
        {_, _, rw, rh} -> {rw, rh}
        nil -> {src_w, src_h}
      end

    %{rect: rect, resize: nil, crop: nil, pad: nil}
    |> Map.merge(fit_geometry(plan, sw, sh))
  end

  # ── geometry ──────────────────────────────────────────────────────────────

  # No target size: only rect and format apply.
  defp fit_geometry(%{w: nil, h: nil}, _sw, _sh), do: %{}

  # One side given: scale to it, keep the aspect. `max` never upscales.
  defp fit_geometry(%{w: w, h: nil} = plan, sw, sh) do
    w = if plan.fit in ["max", "min"], do: min(w, sw), else: w
    %{resize: {w, max(round(sh * w / sw), 1)}}
  end

  defp fit_geometry(%{w: nil, h: h} = plan, sw, sh) do
    h = if plan.fit in ["max", "min"], do: min(h, sh), else: h
    %{resize: {max(round(sw * h / sh), 1), h}}
  end

  defp fit_geometry(%{w: w, h: h, fit: "clip"}, sw, sh),
    do: %{resize: contain(sw, sh, w, h, 1.0e9)}

  defp fit_geometry(%{w: w, h: h, fit: "max"}, sw, sh), do: %{resize: contain(sw, sh, w, h, 1.0)}

  defp fit_geometry(%{w: w, h: h, fit: "fill"}, sw, sh),
    do: %{resize: contain(sw, sh, w, h, 1.0e9), pad: {w, h}}

  defp fit_geometry(%{w: w, h: h, fit: "crop"} = plan, sw, sh), do: cover(plan, sw, sh, w, h)

  # `min`: crop to the requested aspect ratio, but never scale up. When the
  # source is smaller than the box, cut the largest w:h area out of it at its
  # own resolution instead.
  defp fit_geometry(%{w: w, h: h, fit: "min"} = plan, sw, sh) do
    if w <= sw and h <= sh do
      cover(plan, sw, sh, w, h)
    else
      ratio = w / h
      cw = min(sw, round(sh * ratio)) |> max(1)
      ch = min(sh, round(cw / ratio)) |> max(1)
      %{crop: crop_box(plan, sw, sh, cw, ch)}
    end
  end

  defp contain(sw, sh, w, h, max_scale) do
    s = Enum.min([w / sw, h / sh, max_scale])
    {max(round(sw * s), 1), max(round(sh * s), 1)}
  end

  defp cover(plan, sw, sh, w, h) do
    s = max(w / sw, h / sh)
    rw = max(ceil(sw * s), w)
    rh = max(ceil(sh * s), h)
    %{resize: {rw, rh}, crop: crop_box(plan, rw, rh, w, h)}
  end

  defp crop_box(%{crop: [mode]}, _rw, _rh, w, h) when mode in ["entropy", "attention"],
    do: {:smart, mode, w, h}

  defp crop_box(plan, rw, rh, w, h) do
    {fx, fy} = anchor(plan)
    left = clamp(round(fx * rw - w / 2), 0, rw - w)
    top = clamp(round(fy * rh - h / 2), 0, rh - h)
    {left, top, w, h}
  end

  # The point the crop centres on, as fractions of the image.
  defp anchor(%{crop: crop, fp: fp}) do
    if "focalpoint" in crop and fp do
      fp
    else
      x =
        cond do
          "left" in crop -> 0.0
          "right" in crop -> 1.0
          true -> 0.5
        end

      y =
        cond do
          "top" in crop -> 0.0
          "bottom" in crop -> 1.0
          true -> 0.5
        end

      {x, y}
    end
  end

  defp clamp_rect(nil, _w, _h), do: nil

  defp clamp_rect({x, y, rw, rh}, src_w, src_h) do
    x = min(x, src_w - 1)
    y = min(y, src_h - 1)
    {x, y, max(min(rw, src_w - x), 1), max(min(rh, src_h - y), 1)}
  end

  defp clamp(_v, lo, hi) when hi < lo, do: lo
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # ── resolve ───────────────────────────────────────────────────────────────

  defp resolve_focal(%{fp: nil, crop: []} = plan, {fx, fy}, size)
       when plan.fit in ["crop", "min"] and is_number(fx) and is_number(fy) do
    case move_into_rect({fx, fy}, plan.rect, size) do
      nil -> plan
      fp -> %{plan | fp: fp, crop: ["focalpoint"]}
    end
  end

  defp resolve_focal(plan, _focal, _size), do: plan

  defp move_into_rect(fp, nil, _size), do: round_fp(fp)

  defp move_into_rect({fx, fy}, {x, y, w, h}, {src_w, src_h}) when w > 0 and h > 0 do
    round_fp({clamp01((fx * src_w - x) / w), clamp01((fy * src_h - y) / h)})
  end

  defp move_into_rect(_fp, _rect, _size), do: nil

  # `auto=format`: AVIF when the client takes it, the backend encodes it and
  # the encode fits the time budget; else WebP when the client takes it; else
  # the plan's `fm` or the source format.
  defp resolve_format(%{auto_format: true} = plan, accept, mime, ctx) when is_binary(accept) do
    cond do
      ctx.avif? and String.contains?(accept, "image/avif") and avif_in_budget?(plan, ctx) ->
        %{plan | fm: "avif"}

      String.contains?(accept, "image/webp") ->
        %{plan | fm: "webp"}

      true ->
        resolve_format(%{plan | auto_format: false}, nil, mime, ctx)
    end
  end

  defp resolve_format(%{fm: "avif"} = plan, _accept, _mime, %{avif?: false}),
    do: %{plan | fm: "webp"}

  defp resolve_format(%{fm: fm} = plan, _accept, _mime, _ctx) when is_binary(fm), do: plan
  defp resolve_format(plan, _accept, mime, _ctx), do: %{plan | fm: default_format(mime)}

  defp avif_in_budget?(plan, %{cost: cost, source_size: size}) do
    case avif_cost(cost) do
      nil ->
        true

      ms_per_mp ->
        case output_pixels(plan, size) do
          nil -> false
          pixels -> pixels / 1_000_000 * ms_per_mp <= avif_budget_ms()
        end
    end
  end

  defp avif_cost(fun) when is_function(fun, 0), do: avif_cost(fun.())
  defp avif_cost(n) when is_number(n) and n > 0, do: n
  defp avif_cost(_), do: nil

  defp default_format("image/png"), do: "png"
  defp default_format("image/gif"), do: "png"
  defp default_format("image/webp"), do: "webp"
  defp default_format(_), do: "jpg"

  # ── parsing ───────────────────────────────────────────────────────────────

  defp dimension(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      raw ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n > 0 -> {:ok, n |> min(max_dimension()) |> step()}
          _ -> invalid(key, "must be a positive integer")
        end
    end
  end

  defp step(n) when n <= 100, do: n

  defp step(n) do
    s = dimension_step()
    min(div(n + s - 1, s) * s, max_dimension())
  end

  defp enum(params, key, allowed, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      v ->
        if v in allowed,
          do: {:ok, v},
          else: invalid(key, "must be one of #{Enum.join(allowed, ", ")}")
    end
  end

  defp crop_modes(params) do
    case Map.get(params, "crop") do
      v when v in [nil, ""] ->
        {:ok, []}

      v ->
        modes = v |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

        cond do
          modes == [] or not Enum.all?(modes, &(&1 in @crop_modes)) ->
            invalid("crop", "must be one or more of #{Enum.join(@crop_modes, ", ")}")

          length(modes) > 1 and Enum.any?(modes, &(&1 in ["entropy", "attention"])) ->
            invalid("crop", "entropy and attention cannot be combined with another mode")

          true ->
            {:ok, modes |> Enum.uniq() |> Enum.sort()}
        end
    end
  end

  defp rect(params) do
    case Map.get(params, "rect") do
      v when v in [nil, ""] ->
        {:ok, nil}

      v ->
        parts = v |> to_string() |> String.split(",")

        case Enum.map(parts, &Integer.parse(String.trim(&1))) do
          [{x, ""}, {y, ""}, {w, ""}, {h, ""}] when x >= 0 and y >= 0 and w > 0 and h > 0 ->
            {:ok, {x, y, w, h}}

          _ ->
            invalid("rect", "must be left,top,width,height in pixels")
        end
    end
  end

  defp focal_point(params) do
    case {Map.get(params, "fp-x"), Map.get(params, "fp-y")} do
      {nil, nil} ->
        {:ok, nil}

      {x, y} ->
        with {:ok, fx} <- fraction("fp-x", x || "0.5"),
             {:ok, fy} <- fraction("fp-y", y || "0.5") do
          {:ok, round_fp({fx, fy})}
        end
    end
  end

  defp fraction(key, raw) do
    case Float.parse(to_string(raw)) do
      {f, ""} when f >= 0.0 and f <= 1.0 -> {:ok, f}
      _ -> invalid(key, "must be a number from 0 to 1")
    end
  end

  defp format(params) do
    case Map.get(params, "fm") do
      v when v in [nil, ""] ->
        {:ok, nil}

      "jpeg" ->
        {:ok, "jpg"}

      v ->
        if v in @formats,
          do: {:ok, v},
          else: invalid("fm", "must be one of #{Enum.join(@formats, ", ")}")
    end
  end

  defp auto(params) do
    case Map.get(params, "auto") do
      v when v in [nil, ""] -> {:ok, false}
      "format" -> {:ok, true}
      _ -> invalid("auto", "must be format")
    end
  end

  defp quality(params) do
    case Map.get(params, "q") do
      v when v in [nil, ""] ->
        {:ok, @default_quality}

      raw ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n >= 1 and n <= 100 -> {:ok, (round(n / 5) * 5) |> max(5)}
          _ -> invalid("q", "must be an integer from 1 to 100")
        end
    end
  end

  defp invalid(key, message), do: {:error, {:invalid_param, key, message}}

  # ── helpers ───────────────────────────────────────────────────────────────

  defp round_fp({x, y}), do: {Float.round(x / 1, 3), Float.round(y / 1, 3)}

  defp clamp01(v), do: v |> max(0.0) |> min(1.0)

  defp format_rect(nil), do: "-"
  defp format_rect({x, y, w, h}), do: "#{x},#{y},#{w},#{h}"

  defp format_fp(nil), do: "-"

  defp format_fp({x, y}),
    do: "#{:erlang.float_to_binary(x, decimals: 3)},#{:erlang.float_to_binary(y, decimals: 3)}"

  @doc "Largest output side, in pixels."
  @spec max_dimension() :: pos_integer()
  def max_dimension, do: Keyword.get(config(), :max_dimension, 4096)

  defp dimension_step, do: Keyword.get(config(), :dimension_step, 10)

  @doc "Most cached parameter sets one asset may hold."
  @spec max_variants_per_asset() :: pos_integer()
  def max_variants_per_asset, do: Keyword.get(config(), :max_variants_per_asset, 100)

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])
end
