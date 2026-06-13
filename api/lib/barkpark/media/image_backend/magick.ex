defmodule Barkpark.Media.ImageBackend.Magick do
  @moduledoc """
  ImageMagick CLI rendition backend — the native path on Windows, where libvips
  has no prebuilt NIF. Shells out to `magick` (ImageMagick 7; falls back to the
  legacy `convert`), so it needs only the executable on PATH (`scoop install
  imagemagick`) — no NIF, no C toolchain.

  Mirrors the vix pipeline: aspect-preserving fit to the spec's bounding box, an
  optional centered semi-transparent text watermark, write at quality. Output
  format follows `dest`'s extension (already set by the caller).
  """
  @behaviour Barkpark.Media.ImageBackend

  @impl true
  def available?, do: not is_nil(magick_bin())

  @impl true
  def render(src, dest, spec, watermark) do
    case magick_bin() do
      nil ->
        {:error, :imagemagick_not_found}

      bin ->
        args =
          [src, "-resize", "#{spec.max_width}x#{spec.max_height}"] ++
            watermark_args(watermark, spec) ++
            ["-quality", to_string(spec.quality), dest]

        case System.cmd(bin, args, stderr_to_stdout: true, env: portable_env(bin)) do
          {_out, 0} ->
            :ok

          {out, code} ->
            {:error, {:magick_failed, code, String.slice(out, 0, 500)}}
        end
    end
  end

  # A portable ImageMagick build (e.g. scoop's) ships its coder/filter modules
  # under `<exedir>\modules\` and its delegate DLLs (`CORE_RL_*`) beside the exe,
  # but sets no registry keys. Without help IM can't locate the modules, and the
  # modules can't find their sibling delegate DLLs (they load via an altered
  # search path). Point IM at the modules and put the exe dir on the child's PATH
  # so the delegates resolve. Only kicks in for that layout — a normal
  # system-installed IM (no local `modules\coders`) is left to its own defaults.
  defp portable_env(bin) do
    dir = Path.dirname(bin)
    coders = Path.join([dir, "modules", "coders"])

    if File.dir?(coders) do
      [
        {"MAGICK_HOME", dir},
        {"MAGICK_CONFIGURE_PATH", dir},
        {"MAGICK_CODER_MODULE_PATH", coders},
        {"MAGICK_FILTER_MODULE_PATH", Path.join([dir, "modules", "filters"])},
        {"PATH", dir <> path_sep() <> System.get_env("PATH", "")}
      ]
    else
      []
    end
  end

  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  # No watermark.
  defp watermark_args(profile, _spec) when profile in [nil, "", "none"], do: []

  # Centered white text at 35% opacity — the vix backend's look, via -annotate.
  defp watermark_args(profile, spec) when profile in ["draft", "editorial"] do
    [
      "-gravity",
      "center",
      "-pointsize",
      to_string(font_size(spec)),
      "-fill",
      "rgba(255,255,255,0.35)",
      "-annotate",
      "0",
      watermark_label(profile)
    ]
  end

  defp watermark_args(_profile, _spec), do: []

  defp watermark_label("draft"), do: "DRAFT"
  defp watermark_label("editorial"), do: "EDITORIAL USE ONLY"
  defp watermark_label(_), do: "DRAFT"

  # Match the vix heuristic against the rendition's bounding box (no probe needed).
  defp font_size(spec), do: max(18, div(min(spec.max_width, spec.max_height), 12))

  defp magick_bin do
    System.find_executable("magick") || System.find_executable("convert")
  end
end
