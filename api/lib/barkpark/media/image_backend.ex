defmodule Barkpark.Media.ImageBackend do
  @moduledoc """
  Pluggable image-transform backend for renditions.

  libvips (via `:image`/`vix`) is the canonical backend on macOS/Linux/Docker —
  it ships a precompiled NIF there. Windows has no vix prebuilt NIF and no
  supported source build, so on Windows we fall back to the **ImageMagick CLI**
  (`magick`), which is a pure executable (scoop-installable, no NIF). Same
  rendition contract, no `image` dep required.

  Selection precedence:

    1. `config :barkpark, :image_backend, <module>` (tests / explicit override)
    2. OS default: ImageMagick on Windows, Vix elsewhere
  """

  @typedoc """
  A rendition spec: bounding box + output format + quality, plus an optional
  `:crop`. Without `:crop` the resize is aspect-preserving FIT (fits inside the
  box). With `:crop` (e.g. `:attention`) it is an exact-fill CROP — the output is
  exactly `max_width`×`max_height`, the source scaled to cover and centre-cropped.
  """
  @type spec :: %{
          required(:max_width) => pos_integer(),
          required(:max_height) => pos_integer(),
          required(:format) => String.t(),
          required(:quality) => pos_integer(),
          optional(:crop) => atom()
        }

  @typedoc "Watermark profile, already normalized: nil means none."
  @type watermark :: nil | String.t()

  @doc """
  Resize `src` to fit `spec` (aspect-preserving), apply the optional watermark,
  and write to `dest` in `spec.format` at `spec.quality`. `dest`'s extension is
  already correct for the format.
  """
  @callback render(src :: Path.t(), dest :: Path.t(), spec :: spec(), watermark :: watermark()) ::
              :ok | {:error, term()}

  @doc "Whether this backend can run in the current environment."
  @callback available?() :: boolean()

  @doc """
  Run a URL-parameter transform plan (`Barkpark.Media.Transform.parse/1`,
  resolved) on `src` and write the result to `dest` in `plan.fm`. Optional: a
  backend without it answers every on-demand transform with
  `{:error, :transforms_unsupported}` and still serves named presets.
  """
  @callback transform(
              src :: Path.t(),
              dest :: Path.t(),
              plan :: Barkpark.Media.Transform.plan(),
              watermark :: watermark()
            ) :: :ok | {:error, term()}

  @doc "Whether this backend can encode AVIF. Optional; absent means no."
  @callback avif?() :: boolean()

  @doc """
  Measured AVIF encode time on this node, in milliseconds per megapixel of
  output, or nil when unknown. Optional. `auto=format` uses it to pick WebP
  over AVIF when an AVIF encode would exceed the time budget.
  """
  @callback avif_ms_per_megapixel() :: number() | nil

  @optional_callbacks transform: 4, avif?: 0, avif_ms_per_megapixel: 0

  @doc "Whether the selected backend runs URL-parameter transforms."
  @spec transforms?() :: boolean()
  def transforms? do
    mod = impl()
    Code.ensure_loaded?(mod) and function_exported?(mod, :transform, 4)
  end

  @doc "Whether the selected backend can encode AVIF."
  @spec avif?() :: boolean()
  def avif? do
    mod = impl()
    Code.ensure_loaded?(mod) and function_exported?(mod, :avif?, 0) and mod.avif?()
  end

  @doc "The selected backend's measured AVIF cost in ms per megapixel, or nil."
  @spec avif_ms_per_megapixel() :: number() | nil
  def avif_ms_per_megapixel do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :avif_ms_per_megapixel, 0),
      do: mod.avif_ms_per_megapixel(),
      else: nil
  end

  @doc "The selected backend module (config override, else OS default)."
  @spec impl() :: module()
  def impl do
    Application.get_env(:barkpark, :image_backend) || default_impl()
  end

  defp default_impl do
    case :os.type() do
      {:win32, _} -> Barkpark.Media.ImageBackend.Magick
      _ -> Barkpark.Media.ImageBackend.Vix
    end
  end
end
