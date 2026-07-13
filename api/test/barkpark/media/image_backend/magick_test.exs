defmodule Barkpark.Media.ImageBackend.MagickTest do
  # async: false — each test toggles the global `:barkpark, Magick` env
  # (bin/timeout overrides), same race concern as image_backend_test.exs.
  use ExUnit.Case, async: false

  alias Barkpark.Media.ImageBackend.Magick

  # The Magick backend is selected only on Windows in prod, but the resource
  # bound must hold everywhere. These tests inject a STUB executable via the
  # `bin:` override, so they run on any POSIX CI host with no real ImageMagick
  # install. (The stubs are `/bin/sh` scripts, so guard on POSIX.)
  setup_all do
    if match?({:unix, _}, :os.type()) do
      :ok
    else
      {:skip, "stub-executable tests require a POSIX shell"}
    end
  end

  setup do
    original = Application.get_env(:barkpark, Magick)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, Magick)
        val -> Application.put_env(:barkpark, Magick, val)
      end
    end)

    :ok
  end

  @render_spec %{max_width: 100, max_height: 100, quality: 80, format: "jpg"}

  # ---------------------------------------------------------------------------
  # Resource-exhaustion bound — the protective test (FAIL-BEFORE / PASS-AFTER)
  # ---------------------------------------------------------------------------

  # FAIL-BEFORE: on the unbounded code, render calls `System.cmd(bin, args, …)`
  # directly, so this sleeper stub blocks render for the full 2s and it returns
  # {_out, 0} → `:ok` — the assertions below fail (result is :ok, and the call
  # took ~2s, not <1.5s).
  #
  # PASS-AFTER: the OTP deadline (200ms here) fires first, the child is
  # brutal-killed, and render returns the bounded {:error, :magick_timeout}
  # quickly — never blocking on the crafted/huge input.
  test "render/4 kills a shell-out that runs past the deadline and returns :magick_timeout" do
    slow = write_stub_script("sleep 2\nexit 0\n")
    Application.put_env(:barkpark, Magick, bin: slow, timeout_ms: 200)

    dest = tmp_path("timeout_out.jpg")

    {micros, result} =
      :timer.tc(fn -> Magick.render("/tmp/whatever.jpg", dest, @render_spec, nil) end)

    assert result == {:error, :magick_timeout}
    # Bounded: returned well before the 2s stub would have exited on its own.
    assert micros < 1_500_000,
           "render blocked #{micros}µs — the deadline did not bound the shell-out"
  end

  # ---------------------------------------------------------------------------
  # ImageMagick resource ceilings on the command line
  # ---------------------------------------------------------------------------

  test "render/4 passes -limit memory/map/time ceilings AHEAD of the input path" do
    args_out = tmp_path("args_capture.txt")
    # Stub records each argv token on its own line, then exits 0.
    stub = write_stub_script("printf '%s\\n' \"$@\" > #{args_out}\nexit 0\n")
    Application.put_env(:barkpark, Magick, bin: stub, timeout_ms: 5_000)

    src = "/tmp/bomb_src.jpg"
    assert :ok = Magick.render(src, tmp_path("limit_out.jpg"), @render_spec, nil)

    tokens = args_out |> File.read!() |> String.split("\n", trim: true)

    assert "-limit" in tokens
    assert "memory" in tokens
    assert "map" in tokens
    assert "time" in tokens

    # Limits must precede the source so they bound the DECODE of a bomb, not just
    # our downstream resize ops.
    limit_idx = Enum.find_index(tokens, &(&1 == "-limit"))
    src_idx = Enum.find_index(tokens, &(&1 == src))
    assert limit_idx < src_idx, "resource -limit args must come before the input path"
  end

  # ---------------------------------------------------------------------------
  # Happy path + error passthrough still work through the bounded runner
  # ---------------------------------------------------------------------------

  test "render/4 returns :ok when the shell-out exits 0 within the deadline" do
    stub = write_stub_script("exit 0\n")
    Application.put_env(:barkpark, Magick, bin: stub, timeout_ms: 5_000)

    assert :ok = Magick.render("/tmp/src.jpg", tmp_path("ok_out.jpg"), @render_spec, nil)
  end

  test "render/4 surfaces a nonzero exit as {:magick_failed, code, out}" do
    stub = write_stub_script("echo boom\nexit 3\n")
    Application.put_env(:barkpark, Magick, bin: stub, timeout_ms: 5_000)

    assert {:error, {:magick_failed, 3, out}} =
             Magick.render("/tmp/src.jpg", tmp_path("fail_out.jpg"), @render_spec, nil)

    assert out =~ "boom"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Write an executable /bin/sh stub whose body is `body`. The stub stands in for
  # the `magick` binary so these tests need no real ImageMagick install.
  defp write_stub_script(body) do
    path = tmp_path("magick_stub_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp tmp_path(name) do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "magick_test_#{unique}_#{name}")
  end
end
