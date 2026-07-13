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

  # Hard OTP deadline on the shell-out. A child that runs past this is killed and
  # render returns {:error, :magick_timeout} — the render path is never blocked
  # indefinitely by a crafted/huge input. Overridable per-env for tests via
  # `config :barkpark, __MODULE__, timeout_ms: N`.
  @default_timeout_ms 30_000

  # ImageMagick resource ceilings, applied on the command line BEFORE the input
  # so they bound the DECODE of a decompression-bomb (a bomb pins RAM during
  # decode, before any of our resize ops run). `-limit time` is the OS-level
  # self-terminate that complements the OTP deadline: even if closing the port on
  # a brutal-kill leaves the child briefly detached, ImageMagick aborts itself.
  @magick_memory_limit "256MiB"
  @magick_map_limit "512MiB"
  # seconds; kept below @default_timeout_ms so IM self-terminates before the OTP
  # deadline fires on a normal-latency host.
  @magick_time_limit "20"

  @impl true
  def available?, do: not is_nil(magick_bin())

  @impl true
  def render(src, dest, spec, watermark) do
    case magick_bin() do
      nil ->
        {:error, :imagemagick_not_found}

      bin ->
        args =
          limit_args() ++
            [src] ++
            resize_args(spec) ++
            watermark_args(watermark, spec) ++
            ["-quality", to_string(spec.quality), dest]

        run_bounded(bin, args)
    end
  end

  # Run the shell-out under a hard deadline. Task.async runs System.cmd in a
  # linked child; Task.yield waits up to the deadline; on timeout Task.shutdown
  # brutal-kills the child so render returns immediately with a bounded error
  # instead of blocking. The `System.cmd` FORM is unchanged (no shell string —
  # injection is not the vector; src is a server-controlled Media.file_path).
  defp run_bounded(bin, args) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true, env: portable_env(bin)) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:magick_failed, code, String.slice(out, 0, 500)}}

      {:exit, reason} ->
        {:error, {:magick_crashed, reason}}

      nil ->
        {:error, :magick_timeout}
    end
  end

  defp limit_args do
    [
      "-limit",
      "memory",
      @magick_memory_limit,
      "-limit",
      "map",
      @magick_map_limit,
      "-limit",
      "time",
      @magick_time_limit
    ]
  end

  defp timeout_ms, do: Keyword.get(config(), :timeout_ms, @default_timeout_ms)

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])

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

  # Aspect-preserving fit by default. With `:crop` set, cover-and-centre-crop to
  # an exact WxH: `-resize WxH^` scales so the box is fully covered, then
  # `-gravity center -extent WxH` crops the overflow — the exact-card geometry
  # the vix backend's `crop:` produces.
  defp resize_args(%{crop: crop, max_width: w, max_height: h}) when not is_nil(crop) do
    ["-resize", "#{w}x#{h}^", "-gravity", "center", "-extent", "#{w}x#{h}"]
  end

  defp resize_args(%{max_width: w, max_height: h}), do: ["-resize", "#{w}x#{h}"]

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

  # Resolve the binary. A `bin:` config override lets tests inject a stub
  # executable (a sleeper to exercise the deadline, an arg-capture to assert the
  # -limit ceilings) without a real ImageMagick install on the CI host.
  defp magick_bin do
    Keyword.get(config(), :bin) ||
      System.find_executable("magick") ||
      System.find_executable("convert")
  end
end
