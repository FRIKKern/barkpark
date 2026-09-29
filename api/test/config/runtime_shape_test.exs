defmodule Barkpark.Config.RuntimeShapeTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeTaskLeaseTtlTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # BARKPARK_SHAPE is declared by the installing door (cloud provisioner, the
  # Solo doors, the App host) and reported in /status.json. Unset reports null;
  # a known name applies; an unknown name refuses the boot.

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ ~w(BARKPARK_SHAPE)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("BARKPARK_SHAPE")
    :ok
  end

  defp shape_config(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    Config.Reader.read!(@runtime_exs, env: :prod)
    |> get_in([:barkpark, :shape])
  end

  test "unset declares nothing, so status.json reports null" do
    assert shape_config(%{}) == nil
  end

  test "empty declares nothing" do
    assert shape_config(%{"BARKPARK_SHAPE" => ""}) == nil
  end

  test "each of the three shapes applies, case and whitespace ignored" do
    assert shape_config(%{"BARKPARK_SHAPE" => "cloud"}) == "cloud"
    assert shape_config(%{"BARKPARK_SHAPE" => "solo"}) == "solo"
    assert shape_config(%{"BARKPARK_SHAPE" => " App "}) == "app"
  end

  test "an unknown name refuses the boot, naming the known shapes" do
    err =
      assert_raise ArgumentError, fn -> shape_config(%{"BARKPARK_SHAPE" => "selfhost"}) end

    assert err.message =~ "selfhost"
    assert err.message =~ "cloud,solo,app"
  end
end
