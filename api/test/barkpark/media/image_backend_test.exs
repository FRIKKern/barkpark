defmodule Barkpark.Media.ImageBackendTest do
  # async: false — toggles global :image_backend Application env, same race
  # concern as cdn_test.exs.
  use ExUnit.Case, async: false

  alias Barkpark.Media.ImageBackend

  setup do
    original = Application.get_env(:barkpark, :image_backend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)

    :ok
  end

  test "impl/0 returns configured override module when set" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Magick
  end

  test "impl/0 returns Vix as default on non-Windows" do
    Application.delete_env(:barkpark, :image_backend)
    # This test runs on macOS/Linux CI — the OS default must be Vix.
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Vix
  end

  test "impl/0 returns the last-set override, not an earlier one" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Vix)
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Magick
  end

  test "impl/0 falls back to OS default when config is deleted after being set" do
    Application.put_env(:barkpark, :image_backend, Barkpark.Media.ImageBackend.Magick)
    Application.delete_env(:barkpark, :image_backend)
    # On non-Windows this must revert to Vix
    assert ImageBackend.impl() == Barkpark.Media.ImageBackend.Vix
  end
end
