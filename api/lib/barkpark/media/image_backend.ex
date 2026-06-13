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

  @typedoc "A rendition spec: bounding box + output format + quality."
  @type spec :: %{
          required(:max_width) => pos_integer(),
          required(:max_height) => pos_integer(),
          required(:format) => String.t(),
          required(:quality) => pos_integer()
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
